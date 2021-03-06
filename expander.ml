open Asttypes
open Typedtree
open Types
open Path

(* output channel *)
let ppf = Format.formatter_of_out_channel stdout

(* select_mode *)
type select_mode = Refine | RefineArg | Match | If | ShowGoal

(********** add types of variables to env **********)

(* 環境の型。Env.t とは別物なのに注意 *)
(* type env_t = string * type_expr *)

(* add_pattern : env_t -> Typedtree.pattern -> env_t *)
(* add all the pattern variables and their types to env *)
let rec add_pattern env pat = match pat.pat_desc with
    Tpat_any -> env
  | Tpat_var (_, {txt = st}) -> (st, pat.pat_type) :: env
  | Tpat_alias (p, _, {txt = st}) -> (st, pat.pat_type) :: add_pattern env p
  | Tpat_constant (_) -> env
  | Tpat_tuple (ps) -> List.fold_left add_pattern env ps
  | Tpat_construct (_, _, ps) -> List.fold_left add_pattern env ps
  | Tpat_variant (_, None, _) -> env
  | Tpat_variant (_, Some (p), _) -> add_pattern env p
  | Tpat_record (lst, _) ->
      List.fold_left (fun env (_, _, p) -> add_pattern env p) env lst
  | Tpat_array (ps) -> List.fold_left add_pattern env ps
  | Tpat_or (p1, p2, _) -> add_pattern (add_pattern env p1) p2
  | Tpat_lazy (p) -> add_pattern env p

(* add_bindings : env_t -> value_binding list -> env_t *)
let add_bindings env bindings =
  List.fold_left (fun env {vb_pat = pat} -> add_pattern env pat)
                 env bindings

(********** obtain types of hole and variables **********)

(* type_of_hole_in_expr : int -> expression -> type_expr * env_t *)
let rec type_of_hole_in_expr n expr = match expr.exp_desc with
    Texp_ident (_, _, _) -> raise Not_found
  | Texp_constant (_) -> raise Not_found
  | Texp_let (rec_flag, bindings, expr) ->
      begin try
        type_of_hole_in_bindings n rec_flag bindings
      with
        Not_found ->
          let (typ, env) = type_of_hole_in_expr n expr in
          (typ, add_bindings env bindings)
      end
  | Texp_function (_, cases, _) -> type_of_hole_in_cases n cases
  | Texp_apply ({exp_desc = Texp_ident (_, {txt = Lident ("exit")}, _)},
                [(_, Some ({exp_desc = Texp_constant (Const_int (m))}), _)])
    when m = n -> (* exit n を発見 *)
      (expr.exp_type, []) (* 穴の型と空の環境を返す *)
  | Texp_apply (expr, lst) ->
      begin try
        type_of_hole_in_expr n expr
      with
        Not_found ->
          let lst1 = List.filter (function (_, None, _) -> false
                                     | (_, Some (_), _) -> true) lst in
          let lst2 = List.map (function (_, None, _) -> assert false
                               | (_, Some (expr), _) -> expr) lst1 in
          type_of_hole_in_exprs n lst2
      end
  | Texp_match (expr, cases1, cases2, _) ->
      (* cases1 for values, cases2 for exceptions *)
      begin try
        type_of_hole_in_expr n expr
      with
        Not_found ->
          begin try
            type_of_hole_in_cases n cases1
          with
            Not_found -> type_of_hole_in_cases n cases2
          end
      end
  | Texp_try (expr, cases) ->
      begin try
        type_of_hole_in_expr n expr
      with
        Not_found -> type_of_hole_in_cases n cases
      end
  | Texp_tuple (exprs) -> type_of_hole_in_exprs n exprs
  | Texp_construct (_, _, exprs) -> type_of_hole_in_exprs n exprs
  | Texp_variant (_, None) -> raise Not_found
  | Texp_variant (_, Some (expr)) -> type_of_hole_in_expr n expr
  | Texp_record (lst, None) ->
      type_of_hole_in_exprs n (List.map (fun (_, _, expr) -> expr) lst)
  | Texp_record (lst, Some (expr)) ->
      type_of_hole_in_exprs n (expr :: List.map (fun (_, _, expr) -> expr) lst)
  | Texp_field (expr, _, _) -> type_of_hole_in_expr n expr
  | Texp_setfield (expr1, _, _, expr2) -> type_of_hole_in_exprs n [expr1; expr2]
  | Texp_array (exprs) -> type_of_hole_in_exprs n exprs
  | Texp_ifthenelse (expr1, expr2, None) ->
      type_of_hole_in_exprs n [expr1; expr2]
  | Texp_ifthenelse (expr1, expr2, Some (expr3)) ->
      type_of_hole_in_exprs n [expr1; expr2; expr3]
  | Texp_sequence (expr1, expr2) -> type_of_hole_in_exprs n [expr1; expr2]
  | Texp_while (expr1, expr2) -> type_of_hole_in_exprs n [expr1; expr2]
  | Texp_for (_, pat, expr1, expr2, _, expr3) ->
      (* pat is currently ignored *)
      type_of_hole_in_exprs n [expr1; expr2; expr3]
  | Texp_send (expr1, _, None) -> type_of_hole_in_expr n expr
  | Texp_send (expr1, _, Some (expr2)) -> type_of_hole_in_exprs n [expr1; expr2]
  | Texp_new (_, _, _) -> raise Not_found
  | Texp_instvar (_, _, _) -> raise Not_found
  | Texp_setinstvar (_, _, _, expr) -> type_of_hole_in_expr n expr
  | Texp_override (_, lst) ->
      type_of_hole_in_exprs n (List.map (fun (_, _, expr) -> expr) lst)
  | Texp_letmodule (_, _, module_expr, expr) ->
      (* module_expr is currently ignored *)
      type_of_hole_in_expr n expr
  | Texp_assert (expr) -> type_of_hole_in_expr n expr
  | Texp_lazy (expr) -> type_of_hole_in_expr n expr
  | Texp_object (_, _) -> raise Not_found
  | Texp_pack (_) -> raise Not_found

(* type_of_hole_in_exprs : int -> expression list -> type_expr * env_t *)
and type_of_hole_in_exprs n exprs = match exprs with
    [] -> raise Not_found
  | expr :: rest ->
      begin try
        type_of_hole_in_expr n expr
      with
        Not_found -> type_of_hole_in_exprs n rest
      end

(* type_of_hole_in_cases : int -> case list -> type_expr * env_t *)
and type_of_hole_in_cases n cases = match cases with
    [] -> raise Not_found
  | {c_lhs = pat; c_guard = None; c_rhs = expr} :: rest ->
      begin try
        let (typ, env) = type_of_hole_in_expr n expr in
        (typ, add_pattern env pat)
      with
        Not_found -> type_of_hole_in_cases n rest
      end
  | {c_lhs = pat; c_guard = Some (gexpr); c_rhs = expr} :: rest ->
      begin try
        let (typ, env) = type_of_hole_in_exprs n [gexpr; expr] in
        (typ, add_pattern env pat)
      with
        Not_found -> type_of_hole_in_cases n rest
      end

(* type_of_hole_in_bindings : int -> rec_flag -> value_binding list ->
                              type_expr * env_t *)
and type_of_hole_in_bindings n rec_flag bindings = match bindings with
    [] -> raise Not_found
  | {vb_expr = expr} :: rest ->
      begin try
        let (typ, env) = type_of_hole_in_expr n expr in
        if rec_flag = Recursive
        then (typ, add_bindings env bindings)
        else (typ, env)
      with
        Not_found -> type_of_hole_in_bindings n rec_flag rest
      end

(* type_of_hole_in_structure : int -> structure_item list ->
                               type_expr * env_t *)
let rec type_of_hole_in_structure n s_items =
  begin match s_items with
      [] -> Format.fprintf ppf "@[Error (Expander): hole %d is not found.@]@." n;
      exit 0
    | {str_desc = Tstr_value (rec_flag, bindings)} :: rest ->
      begin try
          type_of_hole_in_bindings n rec_flag bindings
        with
          Not_found -> type_of_hole_in_structure n rest
      end
    | {str_desc = _} :: rest -> type_of_hole_in_structure n rest
  end

(********** main **********)

(* main : Typedtree.structure -> int -> (type_expr * env_t) *)
(* 本当は unit を返していた *)
(* type_expr is in Types.ml *)
let main structure n =
  (* n 番の穴の型とそこから見える変数の型を得る *)
  let (typ, env) = type_of_hole_in_structure n structure.str_items in
  (*
  Format.fprintf ppf "@[type of hole:@ %a@]@." (* 穴の型を表示 *)
    Printtyp.type_expr typ;
  List.iter (fun (v, typ) ->                   (* 変数の型を表示 *)
              Format.fprintf ppf "@[%s : %a@]@."
                v Printtyp.type_expr typ)
            env;
   *)
  (typ, env)

(********** entry point of the expander **********)
let holenum = ref (-1)
		  
(* gensym: unit -> unit *)
let gensym () = holenum := (!holenum + 1)

let rec match_types_expr expr = match expr.desc with
    Tvar (Some(s)) -> Format.fprintf ppf "Tvar %s@." s
  | Tvar (_) -> Format.fprintf ppf "Tvar None@."
  | Tarrow (lbl, e1, e2, _) -> Format.fprintf ppf "Tarrow: %s@." lbl;
			       match_types_expr e1;
			       match_types_expr e2
  | Ttuple (el) -> Format.fprintf ppf "Ttuple@.";
		   List.iter (fun e -> match_types_expr e) el
  | Tconstr (name, el, _) -> Format.fprintf ppf "Tconstr %a@." Printtyp.path name;
			     List.iter (fun e -> match_types_expr e) el
  | Tobject (e, _) -> Format.fprintf ppf "Tobject@.";
		      match_types_expr e
  | Tfield (s, _, e1, e2) -> Format.fprintf ppf "Tfield %s@." s;
			     match_types_expr e1;
			     match_types_expr e2
  | Tnil -> Format.fprintf ppf "Tnil@."
  | Tlink (e) -> Format.fprintf ppf "Tlink@.";
		 match_types_expr e
  | Tsubst (e) -> Format.fprintf ppf "Tsubst@.";
		  match_types_expr e
  | Tvariant ({row_more=row_more}) -> Format.fprintf ppf "Tvariant@.";
				      match_types_expr row_more
  | Tunivar (_) -> Format.fprintf ppf "Tunivar@."
  | Tpoly (_, _) -> Format.fprintf ppf "Tpoly@."
  | Tpackage (_, _, _) -> Format.fprintf ppf "Tpackage@."

(* is_equal_type: type_expr -> type_expr -> bool *)
let rec is_equal_type typ1 typ2 =
  match (typ1.desc, typ2.desc) with
    (Tvar (Some(s1)), Tvar (Some(s2))) -> ((*Format.fprintf ppf "Tvar: %s %s@." s1 s2; *)
					   if s1 = s2 then true else false)
  | (Tvar (None), Tvar (None)) -> ((*Format.fprintf ppf "Tvar: None@."; *) true)
  | (Tvar (_), Tvar (_)) -> ((*Format.fprintf ppf "Tvar: others@."; *) false)
  | (Tarrow (_, v1, b1, _), Tarrow (_, v2, b2, _)) -> ((*Format.fprintf ppf "Tarrow@."; *)
						      (is_equal_type v1 v2) && (is_equal_type b1 b2))
  | (Ttuple (el1), Ttuple (el2)) -> ((* Format.fprintf ppf "Ttuple@.";*)
				    if (List.length el1) = (List.length el2)
				    then List.fold_left (&&) true
							(List.rev_map2 (fun e1 e2 -> is_equal_type e1 e2) el1 el2)
				    else false)
  | (Tconstr (s1, el1, _), Tconstr (s2, el2, _)) -> ((*Format.fprintf ppf "Tconstr@.";*)
						    if Path.same s1 s2
						    then List.fold_left (&&) true
									(List.rev_map2 (fun e1 e2 -> is_equal_type e1 e2) el1 el2)
						    else false)
  | (_, Tlink (e)) -> is_equal_type typ1 e
  | (Tlink (e), _) -> is_equal_type e typ2
  | (_, _) -> Format.fprintf ppf "Error: Others: typ1 has %a while typ2 has %a@." Printtyp.type_expr typ1 Printtyp.type_expr typ2; false
  (*
  | (Tobject (_, _), Tobject (_, _)) -> Format.fprintf ppf "Tobject@."
  | Tfield (_, _, _, _) -> Format.fprintf ppf "Tfield@."
  | Tnil -> Format.fprintf ppf "Tnil@."
  | Tlink (_) -> Format.fprintf ppf "Tlink@."
  | Tsubst (_) -> Format.fprintf ppf "Tsubst@."
  | Tvariant (_) -> Format.fprintf ppf "Tvariant@."
  | Tunivar (_) -> Format.fprintf ppf "Tunivar@."
  | Tpoly (_, _) -> Format.fprintf ppf "Tpoly@."
  | Tpackage (_, _, _) -> Format.fprintf ppf "Tpackage@."
   *)
  
(* type t_kind: Record or Variant *)
type t_kind = Record of (string * core_type list) list | Variant of (string * core_type list) list
	      | List
			 
(* zip_field: Typedtree.label_declaration -> (string, type_expr list) *)		       
let zip_field (ld: Typedtree.label_declaration) = match ld with
    {ld_id = id; ld_type = typ} -> (id.name, [typ])
  | _ -> failwith "zip_field: this is not label_decration"
				   
(* zip_fields: Typedtree.label_declaration list -> (string, core_type list) list *)
let zip_fields lst = List.map zip_field lst

(* zip_constructor: Typedtree.constructor_declaration -> (string, core_type list) *)
let zip_constructor (cd: Typedtree.constructor_declaration) = match cd with
    {cd_id = id; cd_args = args} -> (id.name, args)

(* zip_constructors: Typedtree.constructor_declaration list -> (string, core_type list) list *)
let zip_constructors (lst: Typedtree.constructor_declaration list) = List.map zip_constructor lst

(* find_constructor: string -> Typedtree.type_declaration list -> t_kind list *)
let rec find_constructor name lst =
  match lst with
    [] -> []
  | (declaration :: rest) ->
     begin match declaration with
	     {typ_id = id; typ_kind = kind} ->
	       begin match kind with
		       Ttype_record (label_declaration_list) ->
		       if id.name = name
		       then Record (zip_fields label_declaration_list) :: find_constructor name rest
		       else find_constructor name rest
		     | Ttype_variant (constructor_declaration_list) ->
			if id.name = name
			then Variant (zip_constructors constructor_declaration_list) :: find_constructor name rest
			else find_constructor name rest
		     | _ -> (* Format.fprintf ppf "this is neither record or variant@.";*)
			    find_constructor name rest
	       end
	   | _ -> (* Format.fprintf ppf "this is not Types.type_declaration@."; *)
		    []
     end

(* print_structure_item: Typedtree.strucre_item -> unit *)
let print_structure_item item = match item.str_desc with
    Tstr_eval (_, _) -> Format.fprintf ppf "Tstr_eval@."
  | Tstr_value (_, _) -> Format.fprintf ppf "Tstr_value@."
  | Tstr_primitive (_) -> Format.fprintf ppf "Tstr_primitive@."
  | Tstr_type (_) -> Format.fprintf ppf "Tstr_type@."
  | Tstr_typext (_) -> Format.fprintf ppf "Tstr_typext@."
  | Tstr_exception (_) -> Format.fprintf ppf "Tstr_exception@."
  | Tstr_module (_) -> Format.fprintf ppf "Tstr_module@."
  | Tstr_recmodule (_) -> Format.fprintf ppf "Tstr_recmodule@."
  | Tstr_modtype (_) -> Format.fprintf ppf "Tstr_modtype@."
  | Tstr_open (_) -> Format.fprintf ppf "Tstr_open@."
  | Tstr_class (_) -> Format.fprintf ppf "Tstr_class@."
  | Tstr_class_type (_) -> Format.fprintf ppf "Tstr_class_type@."
  | Tstr_include (_) -> Format.fprintf ppf "Tstr_include@."
  | Tstr_attribute (_) -> Format.fprintf ppf "Tstr_attribute@."
    
(* find_constructors: Path.t -> Typedtree.structure_item list -> t_kind list *)
(* path (ユーザ定義の variant の名前) の型情報を structure から探す *)
let rec find_constructors path structure_items =
  match path with
    Pident (ident) ->
    begin match structure_items with
	    [] -> []
	  | item :: rest -> (* Format.fprintf ppf "structure_item@.";*)
	     begin match item.str_desc with
		     Tstr_type (type_declarations) ->
		     if ident.name = "list" then [List]
		     else (find_constructor ident.name type_declarations) @ (find_constructors path rest)
		   | _ -> (* print_structure_item item; *)
			  find_constructors path rest
	     end
    end
  | _ -> Format.fprintf ppf "path is not Pident@.";
	 raise Not_found

(* find_fields: Types.type_expr -> Typedtree.type_declaration list -> t_kind list *)
let find_fields typ lst = match typ with
    {desc = desc} ->
    (* name が lst から探したい変数名 *)
    begin match desc with
	  | Tconstr (name, _, _) -> (* Format.fprintf ppf "find_fields: Tconstr %a@." Printtyp.path name; *)
				    find_constructors name lst
	  | _ -> Format.fprintf ppf "find_fields: not Tconstr@."; []
    end

(* find_type_of_var: string -> env_t -> Types.type_expr *)
(* type env_t = string * type_expr *)
let rec find_type_of_var x env = match env with
    [] -> Format.fprintf ppf "mt@.";
    let str = Printf.sprintf "variable %s is not found in this scope@." x in
    failwith str
  | ((v, typ) :: r) -> (* Format.fprintf ppf "not mt, %s: %a@." v Printtyp.type_expr typ; *)
		       if v = x
		       then typ (* e.g. returns "int list" when matching List *)
		       else find_type_of_var x r

(* type t_kind = Record of (string * core_type list) list | Variant of (string * core_type list) list *)
(* print_t_kind: t_kind -> unit *)
let print_t_kind kind =
  begin match kind with
	  List -> Format.fprintf ppf "[] -> exit(*{ }*)@.";
		  Format.fprintf ppf "| (var0 :: var1) -> exit(*{ }*)@."
	| Record (lst) ->
	   let s = "{" in
	   (* Format.fprintf ppf "{@."; *)
	   let rec loop l str = match l with
	       [] -> str ^ "} -> exit(*{ }*)"
	     | [(name, _)] -> loop [] (str ^ name ^ " = " ^ name)
	     | ((name, _) :: r) -> loop r (str ^ name ^ " = " ^ name ^ ", ")
	   in
	   let str = loop lst s in
	   Format.fprintf ppf "%s@." str;
	| Variant (lst) ->
	   List.iter (fun (name, ts) ->
		      let length = List.length ts in
		      if length = 0 then (* e.g. Empty -> hole *)
			begin
			  Format.fprintf ppf "| %s -> exit(*{ }*)@." name
			end
		      else
			let s = "| " ^ name ^ " (" in
			let rec loop lst n str = match lst with
			    [] -> str
			  | [t] ->
			     begin
			       gensym ();
			       str ^ ("var" ^ string_of_int n) ^ ") -> exit(*{ }*)"
			     end
			  | (t :: r) ->
			     loop r (n + 1) (str ^ "var" ^ (string_of_int n) ^ ", ") in
			let str = loop ts 0 s in
		     Format.fprintf ppf "%s@." str)
		     lst
  end
      
(* print_constructors: string -> t_kind list -> unit *)
let print_t_kinds var kinds =
  Format.fprintf ppf "match %s with@." var;
  List.iter print_t_kind kinds
	    
(* match_variable: int -> string -> -> env_t -> Typedtree.structure -> unit *)
(* 変数 x の型を env から取ってくる -> その型を structure から探して出力 *)
let print_match_expr n x env structure =
  let type_of_x = find_type_of_var x env in (* ユーザ定義の型かどうか調べる, List も "int list" とかが返ってくる *)
  let rec loop typ =
    begin match typ.desc with
	  (* e.g. type tree = Empty | Node of tree * int * tree は Tconstr (tree, _, _) *)
	  (* e.g. List は Tconstr (list, _, _) *)
	  | Tconstr (path, _, _) -> (* Format.fprintf ppf "Tconstr path: %a@." Printtyp.path path; *)
	     let constructors = find_constructors path structure.str_items in
	     print_t_kinds x constructors
	  (* e.g. type t = {a = int, b = int} は Tlink (t) *)
	  | Tlink (t) -> loop t
	  (* Format.fprintf ppf "Tlink: %a@." Printtyp.type_expr typ; *)
	  (* let fields = find_fields typ structure.str_items in
			  print_t_kinds x fields *)
	  | _ -> Format.fprintf ppf "Error: Not Tconstr or Tlink@."; match_types_expr type_of_x
    end
  in loop type_of_x

(* print_refine_record: t_kind list -> unit *)
let print_refine_record kinds =
  let rec loop k =
    match k with
      Record (lst) ->
      let s = "{" in
      (* Format.fprintf ppf "{@."; *)
      let rec loop l str = match l with
	  [] -> str ^ "}"
	| [(name, _)] -> loop [] (str ^ name ^ " = " ^ "exit(*{ }*)")
	| ((name, _) :: r) -> loop r (str ^ name ^ " = " ^ "exit(*{ }*)" ^ ", ")
      in
      let str = loop lst s in
      Format.fprintf ppf "%s@." str;
    | _ -> Format.fprintf ppf "Error: Cannot Refine@."
  in
  List.iter loop kinds
  
(* refine_record: Path.t -> type_expr list structure *)
let refine_record path el structure =
  let fields = find_constructors path structure.str_items in
  print_refine_record fields

(* refine_goal: int -> type_expr -> Typedtree.structure -> unit *)
let rec refine_goal n expr structure =
  begin match expr.desc with
	| Ttuple (lst) ->
	   let rec loop l str =
	     match l with
	       [] -> str
	     | f :: [] ->
		str ^ "exit(*{ }*))"
	     | f :: r ->
		loop r (str ^ "exit(*{ }*), ") in
	   let str = loop lst "(" in
	   (* Format.fprintf ppf "tuple@." *)
	   Format.fprintf ppf "%s@." str
	| Tlink ({desc = Tlink (e)}) -> (* tuple の入れ子 *)
	   refine_goal n e structure
	| Tconstr (name, el, _) -> (* record, `name` is its name *)
	   refine_record name el structure
	| _ -> Format.fprintf ppf "Error: Not_supported@.";
	       match_types_expr expr
  end

(* show_goal: type_expr -> env_t -> unit *)
let show_goal typ env =
  Format.fprintf ppf "@[type of hole:@ %a@]@." (* 穴の型を表示 *)
    Printtyp.type_expr typ;
  List.iter (fun (v, typ) ->                   (* 変数の型を表示 *)
      Format.fprintf ppf "@[%s : %a@]@."
        v Printtyp.type_expr typ)
    env

(* get_matched_variable: int -> string *)
(* n 番目の hole でユーザがどの変数で match したいと入力してるかを取得 *)
let get_matched_variable n =
  (* Format.fprintf ppf "%s@." Sys.argv.(4); *)
  Sys.argv.(4)

(* get_mode: unit -> select_mode *)
let get_mode () = match Sys.argv.(3) with
    "Refine" -> Refine
  | "RefineArg" -> RefineArg
  | "Match" -> Match
  | "If" -> If
  | "ShowGoal" -> ShowGoal
  | _ -> failwith "Error: select_mode is neither Refine or Match"

(* get_type:  Typedtree.structure * Typedtree.module_coercion ->
                 int -> type_expr * env_t *)
let get_type (structure, coercion) n =
  let ppf = Format.formatter_of_out_channel stdout in 
  (*  Format.fprintf ppf "%a@." Printtyped.implementation structure;*)
  begin
    match coercion with
      Typedtree.Tcoerce_none -> (* main structure *)
      let (typ, env) = main structure n in (* typ: goal の型, env: スコープ内の変数の型 *)
      (typ, env)
    | _ -> failwith "Expander: module_coercion not supported yet."
  end
  
(* expander の入り口：型の付いた入力プログラムを受け取ってくる *)
(* Expander.go : Typedtree.structure * Typedtree.module_coercion ->
                 Typedtree.structure * Typedtree.module_coercion *)
(* ./expander filename n mode Some(var) *)
let go (structure, coercion) =
  let n = int_of_string Sys.argv.(2) in
  let mode = get_mode () in
  begin
    match mode with
      Refine -> let (typ, env) = get_type (structure, coercion) n in
      refine_goal n typ structure
    | RefineArg -> let (typ, env) = get_type (structure, coercion) n in
      let var = Sys.argv.(4) in
      let typ_of_var = find_type_of_var var env in
      if is_equal_type typ_of_var typ then Format.fprintf ppf "%s@." var
      else Format.fprintf ppf "Error: Cannot Refine@."
 (*
if typ.desc = typ_of_var.desc then Format.fprintf ppf "%s@." var
else Format.fprintf ppf "Error: cannot refine@.";
Format.fprintf ppf "typ.desc: %a, typ_of_var.desc: %a@."
Printtyp.raw_type_expr typ Printtyp.raw_type_expr typ_of_var
*)
    (* refine_goal_with_argument var typ_of_var typ structure *)
    | Match -> let (typ, env) = get_type (structure, coercion) n in
      let var = get_matched_variable n in
      print_match_expr n var env structure
    | If -> Format.fprintf ppf "if exit(*{ }*) then exit(*{ }*) else exit(*{ }*)@."
    | ShowGoal -> let (typ, env) = get_type (structure, coercion) n in
      show_goal typ env
  end;
  exit 0;
  (structure, coercion) (* 返り値はこの型にしておく *)
