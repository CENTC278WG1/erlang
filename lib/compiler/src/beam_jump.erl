%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1999-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%
%%% Purpose : Optimise jumps and remove unreachable code.

-module(beam_jump).

-export([module/2,module_labels/1,
	 is_unreachable_after/1,is_exit_instruction/1,
	 remove_unused_labels/1,is_label_used_in/2]).

%%% The following optimisations are done:
%%%
%%% (1) This code with two identical instruction sequences
%%% 
%%%     L1: <Instruction sequence>
%%%     L2:
%%%          . . .
%%%     L3: <Instruction sequence>
%%%     L4:
%%%
%%%     can be replaced with
%%% 
%%%     L1: jump L3
%%%     L2:
%%%          . . .
%%%     L3: <Instruction sequence>
%%%     L4
%%%     
%%%     Note: The instruction sequence must end with an instruction
%%%     such as a jump that never transfers control to the instruction
%%%     following it.
%%%
%%% (2) case_end, if_end, and badmatch, and function calls that cause an
%%%     exit (such as calls to exit/1) are moved to the end of the function.
%%%     The purpose is to allow further optimizations at the place from
%%%     which the code was moved.
%%%
%%% (3) Any unreachable code is removed.  Unreachable code is code
%%%     after jump, call_last and other instructions which never
%%%     transfer control to the following instruction.  Code is
%%%     unreachable up to the next *referenced* label.  Note that the
%%%     optimisations below might generate more possibilities for
%%%     removing unreachable code.
%%%
%%% (4) This code:
%%%	L1:	jump L2
%%%          . . .
%%%     L2: ...
%%%
%%%    will be changed to
%%%
%%%    jump L2
%%%          . . .
%%%    L1:
%%%    L2: ...
%%%
%%%    If the jump is unreachable, it will be removed according to (1).
%%%
%%% (5) In
%%%
%%%	 jump L1
%%%      L1:
%%%
%%%	 the jump (but not the label) will be removed.
%%%
%%% (6) If test instructions are used to skip a single jump instruction,
%%%      the test is inverted and the jump is eliminated (provided that
%%%      the test can be inverted).  Example:
%%%
%%%      is_eq L1 {x,1} {x,2}
%%%      jump L2
%%%      L1:
%%%
%%%      will be changed to
%%%
%%%      is_ne L2 {x,1} {x,2}
%%%      L1:
%%%
%%%      Because there may be backward references to the label L1
%%%      (for instance from the wait_timeout/1 instruction), we will
%%%      always keep the label. (beam_clean will remove any unused
%%%      labels.)
%%%
%%% Note: This modules depends on (almost) all branches and jumps only
%%% going forward, so that we can remove instructions (including definition
%%% of labels) after any label that has not been referenced by the code
%%% preceeding the labels. Regarding the few instructions that have backward
%%% references to labels, we assume that they only transfer control back
%%% to an instruction that has already been executed. That is, code such as
%%%
%%%         jump L_entry
%%%
%%%      L_again:
%%%           .
%%%           .
%%%           .
%%%      L_entry:
%%%           .
%%%           .
%%%           .
%%%         jump L_again;
%%%           
%%% is NOT allowed (and such code is never generated by the code generator).
%%%
%%% Terminology note: The optimisation done here is called unreachable-code
%%% removal, NOT dead-code elimination.  Dead code elimination means the
%%% removal of instructions that are executed, but have no visible effect
%%% on the program state.
%%% 

-import(lists, [reverse/1,reverse/2,foldl/3,dropwhile/2]).

module({Mod,Exp,Attr,Fs0,Lc}, _Opt) ->
    Fs = [function(F) || F <- Fs0],
    {ok,{Mod,Exp,Attr,Fs,Lc}}.

module_labels({Mod,Exp,Attr,Fs,Lc}) ->
    {Mod,Exp,Attr,[function_labels(F) || F <- Fs],Lc}.

function_labels({function,Name,Arity,CLabel,Asm0}) ->
    Asm = remove_unused_labels(Asm0),
    {function,Name,Arity,CLabel,Asm}.    

%% function(Function) -> Function'
%%  Optimize jumps and branches.
%%
%%  NOTE: This function assumes that there are no labels inside blocks.
function({function,Name,Arity,CLabel,Asm0}) ->
    Asm1 = share(Asm0),
    Asm2 = move(Asm1),
    Asm3 = opt(Asm2, CLabel),
    Asm = remove_unused_labels(Asm3),
    {function,Name,Arity,CLabel,Asm}.

%%%
%%% (1) We try to share the code for identical code segments by replacing all
%%% occurrences except the last with jumps to the last occurrence.
%%%

share(Is0) ->
    %% We will get more sharing if we never fall through to a label.
    Is = eliminate_fallthroughs(Is0, []),
    share_1(Is, dict:new(), [], []).

share_1([{label,_}=Lbl|Is], Dict, [], Acc) ->
    share_1(Is, Dict, [], [Lbl|Acc]);
share_1([{label,L}=Lbl|Is], Dict0, Seq, Acc) ->
    case dict:find(Seq, Dict0) of
	error ->
	    Dict = dict:store(Seq, L, Dict0),
	    share_1(Is, Dict, [], [Lbl|Seq ++ Acc]);
	{ok,Label} ->
	    share_1(Is, Dict0, [], [Lbl,{jump,{f,Label}}|Acc])
    end;
share_1([{func_info,_,_,_}=I|Is], _, [], Acc) ->
    Is++[I|Acc];
share_1([I|Is], Dict, Seq, Acc) ->
    case is_unreachable_after(I) of
	false ->
	    share_1(Is, Dict, [I|Seq], Acc);
	true ->
	    share_1(Is, Dict, [I], Acc)
    end.


%% Eliminate all fallthroughs. Return the result reversed.

eliminate_fallthroughs([I,{label,L}=Lbl|Is], Acc) ->
    case is_unreachable_after(I) orelse is_label(I) of
	false ->
	    %% Eliminate fallthrough.
	    eliminate_fallthroughs(Is, [Lbl,{jump,{f,L}},I|Acc]);
	true ->
	    eliminate_fallthroughs(Is, [Lbl,I|Acc])
    end;
eliminate_fallthroughs([I|Is], Acc) ->
    eliminate_fallthroughs(Is, [I|Acc]);
eliminate_fallthroughs([], Acc) -> Acc.

is_label({label,_}) -> true;
is_label(_) -> false.
    
%%%
%%% (2) Move short code sequences ending in an instruction that causes an exit
%%% to the end of the function.
%%%
%%% Implementation note: Since share/1 eliminated fallthroughs to labels,
%%% we don't have to test whether instructions before labels may fail through.
%%%
move(Is) ->
    move_1(Is, [], []).

move_1([I|Is], End, Acc) ->
    case is_exit_instruction(I) of
	false -> move_1(Is, End, [I|Acc]);
	true -> move_2(I, Is, End, Acc)
    end;
move_1([], End, Acc) ->
    reverse(Acc, reverse(End)).

move_2(Exit, Is, End, [{block,_},{label,_},{func_info,_,_,_}|_]=Acc) ->
    move_1(Is, End, [Exit|Acc]);
move_2(Exit, Is, End, [{block,_}=Blk,{label,_}=Lbl,Unreachable|More]) ->
    move_1([Unreachable|Is], [Exit,Blk,Lbl|End], More);
move_2(Exit, Is, End, [{bs_context_to_binary,_}=Bs,{label,_}=Lbl,
		       Unreachable|More]) ->
    move_1([Unreachable|Is], [Exit,Bs,Lbl|End], More);
move_2(Exit, Is, End, [{label,_}=Lbl,Unreachable|More]) ->
    move_1([Unreachable|Is], [Exit,Lbl|End], More);
move_2(Exit, Is, End, Acc) ->
    move_1(Is, End, [Exit|Acc]).

%%%
%%% (3) (4) (5) (6) Jump and unreachable code optimizations.
%%%

-record(st, {fc,				%Label for function class errors.
	     entry,				%Entry label (must not be moved).
	     mlbl,				%Moved labels.
	     labels				%Set of referenced labels.
	    }).

opt([{label,Fc}|_]=Is0, CLabel) ->
    Lbls = initial_labels(Is0),
    find_fixpoint(fun(Is) ->
			  St = #st{fc=Fc,entry=CLabel,mlbl=dict:new(),
				   labels=Lbls},
			  opt(Is, [], St)
		  end, Is0).

find_fixpoint(OptFun, Is0) ->
    case OptFun(Is0) of
	Is0 -> Is0;
	Is -> find_fixpoint(OptFun, Is)
    end.

opt([{test,Test0,{f,Lnum}=Lbl,Ops}=I|Is0], Acc, St) ->
    case Is0 of
	[{jump,{f,Lnum}}|Is] ->
	    %% We have
	    %%    Test Label Ops
	    %%    jump Label
	    %% The test instruction is definitely not needed.
	    %% The jump instruction is not needed if there is
	    %% a definition of Label following the jump instruction.
	    case is_label_defined(Is, Lnum) of
		false ->
		    %% The jump instruction is still needed.
		    opt(Is0, [I|Acc], label_used(Lbl, St));
		true ->
		    %% Neither the test nor the jump are needed.
		    opt(Is, Acc, St)
	    end;
	[{jump,To}|Is] ->
	    case is_label_defined(Is, Lnum) of
		false ->
		    opt(Is0, [I|Acc], label_used(Lbl, St));
		true ->
		    case invert_test(Test0) of
			not_possible ->
			    opt(Is0, [I|Acc], label_used(Lbl, St));
			Test ->
			    opt([{test,Test,To,Ops}|Is], Acc, St)
		    end
	    end;
	_Other ->
	    opt(Is0, [I|Acc], label_used(Lbl, St))
    end;
opt([{test,_,{f,_}=Lbl,_,_,_}=I|Is], Acc, St) ->
    opt(Is, [I|Acc], label_used(Lbl, St));
opt([{select_val,_R,Fail,{list,Vls}}=I|Is], Acc, St) ->
    skip_unreachable(Is, [I|Acc], label_used([Fail|Vls], St));
opt([{select_tuple_arity,_R,Fail,{list,Vls}}=I|Is], Acc, St) ->
    skip_unreachable(Is, [I|Acc], label_used([Fail|Vls], St));
opt([{label,L}=I|Is], Acc, #st{entry=L}=St) ->
    %% NEVER move the entry label.
    opt(Is, [I|Acc], St);
opt([{label,L1},{jump,{f,L2}}=I|Is], [Prev|Acc], St0) ->
    St = St0#st{mlbl=dict:append(L2, L1, St0#st.mlbl)},
    opt([Prev,I|Is], Acc, label_used({f,L2}, St));
opt([{label,Lbl}=I|Is], Acc, #st{mlbl=Mlbl}=St0) ->
    case dict:find(Lbl, Mlbl) of
	{ok,Lbls} ->
	    %% Essential to remove the list of labels from the dictionary,
	    %% since we will rescan the inserted labels.  We MUST rescan.
	    St = St0#st{mlbl=dict:erase(Lbl, Mlbl)},
	    insert_labels([Lbl|Lbls], Is, Acc, St);
	error -> opt(Is, [I|Acc], St0)
    end;
opt([{jump,{f,Lbl}},{label,Lbl}=I|Is], Acc, St) ->
    opt([I|Is], Acc, St);
opt([{jump,Lbl}=I|Is], Acc, St) ->
    skip_unreachable(Is, [I|Acc], label_used(Lbl, St));
%% Optimization: quickly handle some common instructions that don't
%% have any failure labels and where is_unreachable_after(I) =:= false.
opt([{block,_}=I|Is], Acc, St) ->
    opt(Is, [I|Acc], St);
opt([{kill,_}=I|Is], Acc, St) ->
    opt(Is, [I|Acc], St);
opt([{call,_,_}=I|Is], Acc, St) ->
    opt(Is, [I|Acc], St);
opt([{deallocate,_}=I|Is], Acc, St) ->
    opt(Is, [I|Acc], St);
%% All other instructions.
opt([I|Is], Acc, #st{labels=Used0}=St0) ->
    Used = ulbl(I, Used0),
    St = St0#st{labels=Used},
    case is_unreachable_after(I) of
	true  -> skip_unreachable(Is, [I|Acc], St);
	false -> opt(Is, [I|Acc], St)
    end;
opt([], Acc, #st{fc=Fc,mlbl=Mlbl}) ->
    Code = reverse(Acc),
    case dict:find(Fc, Mlbl) of
 	{ok,Lbls} -> insert_fc_labels(Lbls, Mlbl, Code);
 	error -> Code
    end.

insert_fc_labels([L|Ls], Mlbl, Acc0) ->
    Acc = [{label,L}|Acc0],
    case dict:find(L, Mlbl) of
	error ->
	    insert_fc_labels(Ls, Mlbl, Acc);
	{ok,Lbls} ->
	    insert_fc_labels(Lbls++Ls, Mlbl, Acc)
    end;
insert_fc_labels([], _, Acc) -> Acc.

%% label_defined(Is, Label) -> true | false.
%%  Test whether the label Label is defined at the start of the instruction
%%  sequence, possibly preceeded by other label definitions.
%%
is_label_defined([{label,L}|_], L) -> true;
is_label_defined([{label,_}|Is], L) -> is_label_defined(Is, L);
is_label_defined(_, _) -> false.

%% invert_test(Test0) -> not_possible | Test

invert_test(is_ge) ->       is_lt;
invert_test(is_lt) ->       is_ge;
invert_test(is_eq) ->       is_ne;
invert_test(is_ne) ->       is_eq;
invert_test(is_eq_exact) -> is_ne_exact;
invert_test(is_ne_exact) -> is_eq_exact;
invert_test(_) ->           not_possible.

insert_labels([L|Ls], Is, [{jump,{f,L}}|Acc], St) ->
    insert_labels(Ls, [{label,L}|Is], Acc, St);
insert_labels([L|Ls], Is, Acc, St) ->
    insert_labels(Ls, [{label,L}|Is], Acc, St);
insert_labels([], Is, Acc, St) ->
    opt(Is, Acc, St).

%% skip_unreachable([Instruction], St).
%%  Remove all instructions (including definitions of labels
%%  that have not been referenced yet) up to the next
%%  referenced label, then call opt/3 to optimize the rest
%%  of the instruction sequence.
%%
skip_unreachable([{label,L}|_Is]=Is0, [{jump,{f,L}}|Acc], St) ->
    opt(Is0, Acc, St);
skip_unreachable([{label,L}|Is]=Is0, Acc, St) ->
    case is_label_used(L, St) of
	true  -> opt(Is0, Acc, St);
	false -> skip_unreachable(Is, Acc, St)
    end;
skip_unreachable([_|Is], Acc, St) ->
    skip_unreachable(Is, Acc, St);
skip_unreachable([], Acc, St) ->
    opt([], Acc, St).

%% Add one or more label to the set of used labels.

label_used({f,L}, St) -> St#st{labels=gb_sets:add(L, St#st.labels)};
label_used([H|T], St0) -> label_used(T, label_used(H, St0));
label_used([], St) -> St;
label_used(_Other, St) -> St.

%% Test if label is used.

is_label_used(L, St) ->
    gb_sets:is_member(L, St#st.labels).

%% is_unreachable_after(Instruction) -> boolean()
%%  Test whether the code after Instruction is unreachable.

is_unreachable_after({func_info,_M,_F,_A}) -> true;
is_unreachable_after(return) -> true;
is_unreachable_after({call_ext_last,_Ar,_ExtFunc,_D}) -> true;
is_unreachable_after({call_ext_only,_Ar,_ExtFunc}) -> true;
is_unreachable_after({call_last,_Ar,_Lbl,_D}) -> true;
is_unreachable_after({call_only,_Ar,_Lbl}) -> true;
is_unreachable_after({apply_last,_Ar,_N}) -> true;
is_unreachable_after({jump,_Lbl}) -> true;
is_unreachable_after({select_val,_R,_Lbl,_Cases}) -> true;
is_unreachable_after({select_tuple_arity,_R,_Lbl,_Cases}) -> true;
is_unreachable_after({loop_rec_end,_}) -> true;
is_unreachable_after({wait,_}) -> true;
is_unreachable_after(I) -> is_exit_instruction(I).

%% is_exit_instruction(Instruction) -> boolean()
%%  Test whether the instruction Instruction always
%%  causes an exit/failure.

is_exit_instruction({call_ext,_,{extfunc,M,F,A}}) ->
    erl_bifs:is_exit_bif(M, F, A);
is_exit_instruction({call_ext_last,_,{extfunc,M,F,A},_}) ->
    erl_bifs:is_exit_bif(M, F, A);
is_exit_instruction({call_ext_only,_,{extfunc,M,F,A}}) ->
    erl_bifs:is_exit_bif(M, F, A);
is_exit_instruction(if_end) -> true;
is_exit_instruction({case_end,_}) -> true;
is_exit_instruction({try_case_end,_}) -> true;
is_exit_instruction({badmatch,_}) -> true;
is_exit_instruction(_) -> false.

%% is_label_used_in(LabelNumber, [Instruction]) -> boolean()
%%  Check whether the label is used in the instruction sequence
%%  (including inside blocks).

is_label_used_in(Lbl, Is) ->
    is_label_used_in_1(Is, Lbl, gb_sets:empty()).

is_label_used_in_1([{block,Block}|Is], Lbl, Empty) ->
    lists:any(fun(I) -> is_label_used_in_2(I, Lbl) end, Block)
	orelse is_label_used_in_1(Is, Lbl, Empty);
is_label_used_in_1([I|Is], Lbl, Empty) ->
    Used = ulbl(I, Empty),
    gb_sets:is_member(Lbl, Used) orelse is_label_used_in_1(Is, Lbl, Empty);
is_label_used_in_1([], _, _) -> false.

is_label_used_in_2({set,_,_,Info}, Lbl) ->
    case Info of
	{bif,_,{f,F}} -> F =:= Lbl;
	{alloc,_,{gc_bif,_,{f,F}}} -> F =:= Lbl;
	{'catch',{f,F}} -> F =:= Lbl;
	{alloc,_,_} -> false;
	{put_tuple,_} -> false;
	{put_string,_,_} -> false;
	{get_tuple_element,_} -> false;
	{set_tuple_element,_} -> false;
	_ when is_atom(Info) -> false
    end.

%% remove_unused_labels(Instructions0) -> Instructions
%%  Remove all unused labels. Also remove unreachable
%%  instructions following labels that are removed.

remove_unused_labels(Is) ->
    Used0 = initial_labels(Is),
    Used = foldl(fun ulbl/2, Used0, Is),
    rem_unused(Is, Used, []).

rem_unused([{label,Lbl}=I|Is0], Used, [Prev|_]=Acc) ->
    case gb_sets:is_member(Lbl, Used) of
	false ->
	    Is = case is_unreachable_after(Prev) of
		     true ->
			 dropwhile(fun({label,_}) -> false;
				      (_) -> true
				   end, Is0);
		     false -> Is0
		 end,
	    rem_unused(Is, Used, Acc);
	true ->
	    rem_unused(Is0, Used, [I|Acc])
    end;
rem_unused([I|Is], Used, Acc) ->
    rem_unused(Is, Used, [I|Acc]);
rem_unused([], _, Acc) -> reverse(Acc).

initial_labels(Is) ->
    initial_labels(Is, []).

initial_labels([{label,Lbl}|Is], Acc) ->
    initial_labels(Is, [Lbl|Acc]);
initial_labels([{func_info,_,_,_},{label,Lbl}|_], Acc) ->
    gb_sets:from_list([Lbl|Acc]).

%% ulbl(Instruction, UsedGbSet) -> UsedGbSet'
%%  Update the gb_set UsedGbSet with any function-local labels
%%  (i.e. not with labels in call instructions) referenced by
%%  the instruction Instruction.
%%
%%  NOTE: This function does NOT look for labels inside blocks.

ulbl({test,_,Fail,_}, Used) ->
    mark_used(Fail, Used);
ulbl({test,_,Fail,_,_,_}, Used) ->
    mark_used(Fail, Used);
ulbl({select_val,_,Fail,{list,Vls}}, Used) ->
    mark_used_list(Vls, mark_used(Fail, Used));
ulbl({select_tuple_arity,_,Fail,{list,Vls}}, Used) ->
    mark_used_list(Vls, mark_used(Fail, Used));
ulbl({'try',_,Lbl}, Used) ->
    mark_used(Lbl, Used);
ulbl({'catch',_,Lbl}, Used) ->
    mark_used(Lbl, Used);
ulbl({jump,Lbl}, Used) ->
    mark_used(Lbl, Used);
ulbl({loop_rec,Lbl,_}, Used) ->
    mark_used(Lbl, Used);
ulbl({loop_rec_end,Lbl}, Used) ->
    mark_used(Lbl, Used);
ulbl({wait,Lbl}, Used) ->
    mark_used(Lbl, Used);
ulbl({wait_timeout,Lbl,_To}, Used) ->
    mark_used(Lbl, Used);
ulbl({bif,_Name,Lbl,_As,_R}, Used) ->
    mark_used(Lbl, Used);
ulbl({gc_bif,_Name,Lbl,_Live,_As,_R}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_init2,Lbl,_,_,_,_,_}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_init_bits,Lbl,_,_,_,_,_}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_put_integer,Lbl,_Bits,_Unit,_Fl,_Val}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_put_float,Lbl,_Bits,_Unit,_Fl,_Val}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_put_binary,Lbl,_Bits,_Unit,_Fl,_Val}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_put_utf8,Lbl,_Fl,_Val}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_put_utf16,Lbl,_Fl,_Val}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_put_utf32,Lbl,_Fl,_Val}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_add,Lbl,_,_}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_append,Lbl,_,_,_,_,_,_,_}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_utf8_size,Lbl,_,_}, Used) ->
    mark_used(Lbl, Used);
ulbl({bs_utf16_size,Lbl,_,_}, Used) ->
    mark_used(Lbl, Used);
ulbl(_, Used) -> Used.

mark_used({f,0}, Used) -> Used;
mark_used({f,L}, Used) -> gb_sets:add(L, Used).

mark_used_list([{f,L}|T], Used) ->
    mark_used_list(T, gb_sets:add(L, Used));
mark_used_list([_|T], Used) ->
    mark_used_list(T, Used);
mark_used_list([], Used) -> Used.
