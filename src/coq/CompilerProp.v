(* -------------------------------------------------------------------------- *
 *                     Vellvm - the Verified LLVM project                     *
 *                                                                            *
 *     Copyright (c) 2017 Steve Zdancewic <stevez@cis.upenn.edu>              *
 *                                                                            *
 *   This file is distributed under the terms of the GNU General Public       *
 *   License as published by the Free Software Foundation, either version     *
 *   3 of the License, or (at your option) any later version.                 *
 ---------------------------------------------------------------------------- *)

Require Import Vellvm.Maps Vellvm.Imp.

Require Import QuickChick.QuickChick.
Import QcDefaultNotation. Open Scope qc_scope.

Require Import ZArith String Omega List Equalities MSets.
Import ListNotations.

(* Vellvm dependencies *)
Require Import Vellvm.Ollvm_ast.
Require Import Vellvm.Compiler.
Require Import Vellvm.AstLib.
Require Import Vellvm.CFG.
Require Import Vellvm.StepSemantics.
Require Import Vellvm.Memory.
Require Import Vellvm.Classes.

(* Logical Foundations dependencies *)
Require Import Vellvm.Imp.
Require Import Vellvm.Maps.
Require Import Vellvm.ImpCEvalFun.
Import ListNotations.

Require Import Vellvm.ImpQuickChick.


Require Import compcert.lib.Integers.

(* Equality for the imp final memory states. *)

(* These definitions should probably go in a library *)

Check Int64.eq_dec.

Definition dvalue_of_nat (n:nat) : dvalue :=
  DV (VALUE_Integer (Z.of_nat n)).

Definition dvalue_of_int64 (n: int64) : dvalue :=
  (*!*) DVALUE_I64 n. (*!  DV (VALUE_Integer (Int64.unsigned n)). *)

Definition imp_val_eqb (v1 v2 : dvalue) : bool :=
  match v1, v2 with
  | (DVALUE_I64 z1), (DVALUE_I64 z2) => Int64.eq z1 z2
  | _, _ => false
  end.

Fixpoint imp_memory_eqb (m1 : list dvalue) (m2 : list dvalue) : bool :=
  match m1, m2 with
  | [], [] => true
  | x::xs, y::ys => if imp_val_eqb x y then imp_memory_eqb xs ys else false
  | _, _ => false 
  end.  

(* The executable test function for compiler correctnes. *)

(* TODO: 
     Add a 'run' function to Imp to execute n steps of the
     Imp operational semantics starting from a given state.

     One possible testing issue: the Vellvm code of a given
     imp program will take many more steps.
 *)
Require Import List.


Fixpoint string_of_dvalue' (v : dvalue) :=
  match v with
  | DV expr =>
    match expr with
    | VALUE_Ident id => string_of id
    | VALUE_Integer x => string_of x
    | VALUE_Bool b => string_of b
    | VALUE_Null => "null"
    | VALUE_Zero_initializer => "zero initializer"
    | VALUE_Cstring s => s
    | VALUE_None => "none" 
    | VALUE_Undef => "undef" 
    | OP_IBinop iop t v1 v2 =>
      ((string_of iop) ++ " " ++ (string_of t)
                       ++ " " ++ (string_of_dvalue' v1)
                       ++ " " ++ (string_of_dvalue' v2))%string
    | OP_GetElementPtr t ptrval idxs =>
      "getelementptr"
    | _ => "string_of_dvalue' todo"
    end
  | DVALUE_CodePointer p => "string_of_dvalue' todo (code pointer)"
  | DVALUE_Addr a => "string_of_dvalue' todo (addr)"
  | _ => "string_of_dvalue' (todo)"
  end.

Instance string_of_value : StringOf dvalue := string_of_dvalue'.

Instance string_of_mem : StringOf memory :=
  fun mem => ("[" ++ show_nat (List.length mem) ++ "] " ++ string_of mem)%string.

Definition state_to_string (fv : list id) (st : state) : string :=
  fold_left (fun acc x => (match x with
                        | Id ident => (ident ++ ": " ++ show_int64 (st x) ++ ", ")%string
                        end)) fv "".

Instance string_of_IDSet_elt : StringOf IDSet.elt :=
  fun elem => 
    match elem with
    | Id name => name
    end.

Fixpoint get_first_n_cmds (c : Imp.com) (n : nat) : nat * option Imp.com :=
  match n with
  | O => (O, None)
  | S n' =>
    match c with
    | SKIP => (n', Some SKIP)
    | x ::= a => (n', Some (x ::= a))
    | c1 ;; c2 =>
      let (steps_left1, executed_1) := get_first_n_cmds c1 n in
      match steps_left1 with
      | O => (O, executed_1)
      | S m =>
        let (steps_left2, executed_2) := get_first_n_cmds c2 m in
        match executed_2 with
        | None => (steps_left2, Some c1)
        | Some c2' => (steps_left2, Some (c1 ;; c2'))
        end
      end
    | IFB b THEN c1 ELSE c2 FI => (O, None)
    | WHILE b DO c END => (O, None)
    end
  end.


Fixpoint get_n_instrs_from_blocks (l : list block) (n : nat) : list block :=
  match l with 
  | [] => []
  | first_block :: rest =>
    let instrs := List.firstn n (blk_instrs first_block) in
    let steps_left := (n - (List.length instrs))%nat in
    match steps_left with
    | O => [mk_block (blk_id first_block)
                    instrs
                    (blk_term first_block)
                    (blk_term_id first_block)]
    | S n' =>
      first_block :: get_n_instrs_from_blocks rest steps_left 
    end
  end.

Fixpoint reduce_to_n_instrs (ll_prog : toplevel_entities (list block)) (n : nat):=
  match ll_prog with
  | [] => []
  | TLE_Definition defn :: other_tles =>
    (TLE_Definition
       (mk_definition (list block)
                      (df_prototype defn)
                      (df_args defn)
                      (get_n_instrs_from_blocks (df_instrs defn) n)))
      :: other_tles (* Assuming only one definition *)
  | tle :: other_tles => tle :: (reduce_to_n_instrs other_tles n)
  end.
  
Definition compile_and_execute (c : Imp.com) (n : nat) : err memory :=
  let fvs := IDSet.elements (fv c) in
  let (n', executed) := get_first_n_cmds c n in
  match executed with
  | None => inl "Not enough steps"
  | Some c => 
    match compile c with
    | inl e => inl e
    | inr ll_prog =>
      let ll_prog := reduce_to_n_instrs ll_prog n in 
      let m := modul_of_toplevel_entities ll_prog in
      match mcfg_of_modul m with
      | None => inl "Compilation failed"
      | Some mcfg =>
        match init_state mcfg "imp_command" with
        | inl e => inl "init failed"
        | inr initial_state =>
          let semantics := sem mcfg initial_state in
          let llvm_final_state := MemDFin [] semantics 10000 in
          match llvm_final_state with
          | Some st => inr st
          | None => inl "out of gas"
          end
        end
      end
    end
  end.

(*! Section CompilerProp *)

Definition imp_compiler_correct_aux (p:Imp.com) : Checker :=
  let fvs := IDSet.elements (fv p) in
  match compile p with
  | inl e => whenFail "Compilation failed" false
  | inr ll_prog =>
    let m := modul_of_toplevel_entities ll_prog in
    match mcfg_of_modul m with
    | None => whenFail "Compilation failed" false
    | Some mcfg =>
      match init_state mcfg "imp_command" with
      | inl e => whenFail "init failed" false
      | inr initial_state =>
        let semantics := sem mcfg initial_state in
        let llvm_final_state := MemDFin [] semantics 10000 in
        let imp_state := ceval_step empty_state p 100 in
        match (llvm_final_state, imp_state) with
        | (None, None) => whenFail "both out of gas" true
        | (Some llvm_st, None) => whenFail "imp out of gas" true
        | (None, Some imp_st) => whenFail "llvm out of gas" false 
        | (Some llvm_st, Some imp_st) => 
          let ans_state := List.map (fun x => dvalue_of_int64 (imp_st x)) fvs in
          checker (whenFail ("not equal: llvm: "
                               ++ (string_of llvm_st)
                               ++ "; imp: "
                               ++ (string_of ans_state)
                               ++ "; free vars: "
                               ++ (string_of fvs) (* (elems_to_string fvs) *)
                               ++ "; compiled code: "
                               ++ (string_of ll_prog))
                            (imp_memory_eqb (*!*) (List.rev llvm_st) (*! llvm_st *) ans_state))
        end        
      end
    end
  end.


Definition imp_compiler_correct_bool (p:Imp.com) : bool :=
  let fvs := IDSet.elements (fv p) in
  match compile p with
  | inl e => false
  | inr ll_prog =>
    let m := modul_of_toplevel_entities ll_prog in
    match mcfg_of_modul m with
    | None => false
    | Some mcfg =>
      match init_state mcfg "imp_command" with
      | inl e => false
      | inr initial_state =>
        let semantics := sem mcfg initial_state in
        let llvm_final_state := MemDFin [] semantics 10000 in
        let imp_state := ceval_step empty_state p 100 in
        match (llvm_final_state, imp_state) with
        | (None, None) => true
        | (Some llvm_st, None) => true
        | (None, Some imp_st) => false
        | (Some llvm_st, Some imp_st) => 
          let ans_state := List.map (fun x => dvalue_of_int64 (imp_st x)) fvs in
          imp_memory_eqb (List.rev llvm_st) ans_state
        end        
      end
    end
  end.

Definition compile_aexp_correct_bool (a:aexp) : bool :=
  let p := (Id "fresh_var" ::= a) in
  imp_compiler_correct_bool p.  


Definition compile_bexp_correct_bool (b:bexp) : bool :=
  let p := (IFB b THEN idX ::= ANum (Int64.repr 1) ELSE idY ::= ANum (Int64.repr 2) FI) in
  imp_compiler_correct_bool p.  

Definition compile_aexp_correct (a:aexp) : Checker :=
  let p := (Id "fresh_var" ::= a) in
  imp_compiler_correct_aux p.  


Definition compile_bexp_correct (b:bexp) : Checker :=
  let p := (IFB b THEN idX ::= ANum (Int64.repr 1) ELSE idY ::= ANum (Int64.repr 2) FI) in
  imp_compiler_correct_aux p.  


Definition show_aexp_compilation_result (result : err (Ollvm_ast.value * list elt)) :=
  match result with
  | inl _ => "err" 
  | inr (_, elts) => string_of elts
  end.

Definition show_bexp_compilation_result (result : err (Ollvm_ast.value * list elt)) :=
  match result with
  | inl _ => "err"
  | inr (_ , elts) => string_of elts
  end.


Definition show_result (result : err (toplevel_entities (list block))) :=
  match result with
  | inl _ => "error"
  | inr l => fold_left (fun s tle_blk => (s ++ "; " ++ (string_of tle_blk))%string) l ""
  end.

(* Tests *)

Extract Constant Test.defNumTests => "100".

(*
Definition prog_unshrunk :=
  IFB (BLe (ANum (Int64.repr 0)) (ANum (Int64.repr 0))) THEN
    IFB (BLe (AId idW) (AId W)) THEN
      idX ::= (AMult (AId idY)
                     (APlus (AMult (ANum (Int64.repr 0)) (ANum (Int64.repr 1)))
                            (AId idY)))
    ELSE SKIP
    FI
  ELSE
    idX ::= (AMult (AMult (ANum (Int64.repr 9)) (ANum (Int64.repr 10)))
                   (AMult (AMult (ANum (Int64.repr (-2))) (ANum (Int64.repr 8)))
                          (AId idX)))
  FI.
*)

(*! Section TestSingleAssignmentNonNegNoMinus *)

Existing Instance gen_seq_and_assgn_com.
Existing Instance gen_bexp_with_small_aexp.
Existing Instance gen_adhoc_aexp.
Existing Instance gen_small_nonneg_i64.

(**! QuickChick (forAll (arbitrarySized 0) imp_compiler_correct_aux). *)
(* Shrinking is slow: 
   QuickChick (forAllShrink (arbitrarySized 0) shrink imp_compiler_correct_aux).
 *)

(* Failure because of 
   (1) wrong dvalue_of_int64 in imp_compiler_correct
   (2) compiler compiles literals to DV (VALUE_Integer _) instead of a dummy 
       binary operation following LLVM programs. Modified compilation of 
       free variables and compilation of literals. 
*)
Example prog_literal1 :=
  idW ::= (APlus (AMult (AId idX) (ANum (Int64.repr 2)))
                 (AMult (ANum (Int64.repr 1)) (AId idX))).

Example prog_literal2 :=
  idW ::= APlus (ANum (Int64.repr 0)) (ANum (Int64.repr 0)).

Example prog_literal3 :=
  idW ::= ANum (Int64.repr 0).

(*
Compute (imp_compiler_correct_bool prog_literal2).
Compute (imp_compiler_correct_bool prog_literal3).
 *)

(* QuickChick (forAll (arbitrarySized 0) imp_compiler_correct_aux). Passed tests. *)

Remove Hints gen_seq_and_assgn_com : typeclass_instances.
Remove Hints gen_bexp_with_small_aexp : typeclass_instances.
Remove Hints gen_adhoc_aexp : typeclass_instances.
Remove Hints gen_small_nonneg_i64 : typeclass_instances.

(* End TestSingleAssignmentNonnegNoMinus !*)

(*! Section TestMultAssignmentNonnegNoMinus *)

Existing Instance gen_seq_and_assgn_com.
Existing Instance gen_bexp_with_small_aexp.
Existing Instance gen_adhoc_aexp.
Existing Instance gen_small_nonneg_i64.

(* QuickChick (forAll (arbitrarySized 8) imp_compiler_correct_aux). Passed tests *)

Remove Hints gen_seq_and_assgn_com : typeclass_instances.
Remove Hints gen_bexp_with_small_aexp : typeclass_instances.
Remove Hints gen_adhoc_aexp : typeclass_instances.
Remove Hints gen_small_nonneg_i64 : typeclass_instances.

(*! Section TestIf *)

Existing Instance gen_if_com.
Existing Instance gen_bexp_with_small_aexp.
Existing Instance gen_adhoc_aexp.
Existing Instance gen_small_nonneg_i64.

(* QuickChick (forAllShrink (arbitrarySized 1) shrink imp_compiler_correct_aux). *)

Example prog1 :=
  IFB (BEq (AId idW) (ANum (Int64.repr 0))) THEN SKIP ELSE SKIP FI.

Example prog2 :=
  IFB (BNot BTrue) THEN SKIP ELSE SKIP FI.

Example prog3 :=
  IFB BFalse THEN SKIP ELSE SKIP FI.

(*
Compute (imp_compiler_correct_bool prog1).
Compute (imp_compiler_correct_bool prog2).
Compute (imp_compiler_correct_bool prog3).
Compute (compile prog2).
Compute (compile_and_execute prog2 1000).
*)

(*
If ((ANum 0 + ANum 0) <= (ANum 1 * ANum 0)) then W := (ANum 2 * ANum 0) else X := Y endIf
If (Z <= (ANum 0 * ANum 0)) then Z := ANum 0 else Skip endIf <- incomplete shrinking?
 *)

Remove Hints gen_if_com : typeclass_instances.
Remove Hints gen_bexp_with_small_aexp : typeclass_instances.
Remove Hints gen_adhoc_aexp : typeclass_instances.
Remove Hints gen_small_nonneg_i64 : typeclass_instances.


(* End TestMultipleCom *)