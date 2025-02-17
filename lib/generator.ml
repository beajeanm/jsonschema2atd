open Json_schema_t
open Printf
open Utils

let record_field_name str =
  let cleaned_field_name = Utils.sanitize_name str in
  if String.equal str cleaned_field_name then str else sprintf {|%s <json name="%s">|} cleaned_field_name str

let doc_annotation text = sprintf {|<doc text=%S>|} text

let define_type ~doc ~name ~type_ =
  let doc =
    match doc with
    | None -> ""
    | Some doc -> doc_annotation doc
  in
  sprintf "type %s = %s %s\n" (type_name name) type_ doc

let process_int_type schema =
  match schema.format with
  | None | Some `Int32 -> "int"
  | Some `Int64 -> "int64"
  | _ -> failwith "int has unextected format"

let process_string_type schema =
  match schema.format with 
  | None -> "string"
  | Some `Decimal -> "float"
  | _ -> "string"

let get_ref_name ref =
  let uri, pointer =
    match String.split_on_char '#' ref with
    | [ uri; pointer ] -> uri, Some pointer
    | [ uri ] -> uri, None
    | _ -> failwith (sprintf "Unsupported remote ref value: %s. The URI contains multiple '#'." ref)
  in
  let name_of_path path =
    match path |> String.split_on_char '/' |> List.rev |> List.hd with
    | exception _ -> failwith (sprintf "Unsupported ref value: %s" ref)
    | name -> name
  in
  match pointer with
  | None -> name_of_path uri
  | Some pointer ->
  match String.split_on_char '/' pointer with
  (* OpenAPI defs *)
  | [ ""; "components"; "schemas"; type_name ] -> type_name
  (* JSON Schema defs *)
  | [ ""; ("$defs" | "definitions"); type_name ] -> type_name
  | _ -> name_of_path pointer

let output = Buffer.create 16
let input_toplevel_schemas = ref []

let get_schema_by_ref ~schema ref =
  let defs =
    let defs = List.concat_map Utils.list_of_nonempty [ schema.defs; schema.definitions ] in
    defs @ !input_toplevel_schemas
  in
  List.find_map
    (function
      | name, schema when String.equal (get_ref_name ref) name -> Some schema
      | _ -> None
      )
    defs

let rec ocaml_value_of_json = function
  | (`Bool _ | `Float _ | `Int _ | `Null) as json -> Yojson.Basic.to_string json
  | `String value -> sprintf "\\\"%s\\\"" value
  | `List elements ->
    let list_elements = List.map ocaml_value_of_json elements |> String.concat ";" in
    sprintf "[%s]" list_elements
  | `Assoc _ as json -> failwith (sprintf "can't make ocaml value from: %s" (Yojson.Basic.to_string json))

let make_atd_default_value enum json_value =
  match enum, json_value with
  | Some _, `String default_enum -> sprintf "`%s" (variant_name default_enum)
  | Some _, json ->
    failwith (sprintf "only string enum default values are supported, can't process: %s" (Yojson.Basic.to_string json))
  | None, json -> ocaml_value_of_json json

let nullable = Printf.sprintf "%s nullable"

let merge_all_of schema =
  match schema.all_of with
  | None -> schema
  | Some [] -> failwith "empty allOf is unexpected"
  | Some all_of ->
    let ref_schemas =
      List.filter_map
        (function
          | Obj schema -> Some schema
          | Ref ref -> get_schema_by_ref ~schema ref
          )
        all_of
    in
    let schemas = schema :: ref_schemas in
    let take_first_opt get_fn =
      match schemas |> List.filter_map get_fn with
      | [] -> None
      | first :: _ -> Some first
    in
    let merge_lists get_fn = schemas |> List.map get_fn |> List.flatten in
    let merge_opt_lists get_fn = schemas |> List.filter_map get_fn |> List.flatten |> Utils.nonempty_list_opt in
    {
      schema = take_first_opt (fun schema -> schema.schema);
      all_of = merge_opt_lists (fun schema -> schema.all_of);
      any_of = merge_opt_lists (fun schema -> schema.any_of);
      one_of = merge_opt_lists (fun schema -> schema.one_of);
      not = take_first_opt (fun schema -> schema.not);
      items = take_first_opt (fun schema -> schema.items);
      properties = merge_opt_lists (fun schema -> schema.properties);
      additional_properties = take_first_opt (fun schema -> schema.additional_properties);
      enum =
        schemas
        |> List.filter_map (fun schema -> schema.enum)
        |> Utils.shortest_list
        |> Option.value ~default:[]
        |> Utils.nonempty_list_opt;
      max_length = take_first_opt (fun schema -> schema.max_length);
      min_length = take_first_opt (fun schema -> schema.min_length);
      pattern = take_first_opt (fun schema -> schema.pattern);
      max_items = take_first_opt (fun schema -> schema.max_items);
      min_items = take_first_opt (fun schema -> schema.min_items);
      unique_items = take_first_opt (fun schema -> schema.unique_items);
      max_contains = take_first_opt (fun schema -> schema.max_contains);
      min_contains = take_first_opt (fun schema -> schema.min_contains);
      max_properties = take_first_opt (fun schema -> schema.max_properties);
      min_properties = take_first_opt (fun schema -> schema.min_properties);
      required = merge_lists (fun schema -> schema.required);
      dependent_required = merge_lists (fun schema -> schema.dependent_required);
      format = take_first_opt (fun schema -> schema.format);
      defs = merge_opt_lists (fun schema -> schema.defs);
      definitions = merge_opt_lists (fun schema -> schema.definitions);
      title = take_first_opt (fun schema -> schema.title);
      typ = take_first_opt (fun schema -> schema.typ);
      description = take_first_opt (fun schema -> schema.description);
      default = take_first_opt (fun schema -> schema.default);
      nullable = schemas |> List.exists (fun schema -> schema.nullable);
    }

let rec process_schema_type ~ancestors (schema : schema) =
  let schema = merge_all_of schema in
  let maybe_nullable type_ = if schema.nullable then nullable type_ else type_ in
  match schema.one_of with
  | Some schemas -> process_one_of ~ancestors schemas
  | None ->
  match schema.enum, schema.typ with
  | Some enums, Some String -> process_string_enums enums
  | Some _, Some Integer ->
    (* this is more lenient than it should *)
    maybe_nullable (process_int_type schema)
  | Some _, Some Number ->
    (* this is more lenient than it should *)
    maybe_nullable "float"
  | Some _, Some Boolean ->
    (* this is more lenient than it should *)
    maybe_nullable "bool"
  | Some _, _ -> failwith "only string enums are supported"
  | None, _ ->
  match schema.typ with
  | Some Integer -> maybe_nullable (process_int_type schema)
  | Some Number -> maybe_nullable "float"
  | Some String -> maybe_nullable (process_string_type schema)
  | Some Boolean -> maybe_nullable "bool"
  | Some Array -> maybe_nullable (process_array_type ~ancestors schema |> String.concat " ")
  | Some Object -> process_object_type ~ancestors schema
  | None ->
    (* fallback to untyped if schema type is not defined *)
    maybe_nullable "json"

and process_array_type ~ancestors schema =
  match schema.items with
  | Some schema_or_ref -> [ make_type_from_schema_or_ref ~ancestors schema_or_ref; "list" ]
  | None -> failwith "items is not specified for array"

and process_nested_schema_type ~ancestors schema =
  match merge_all_of schema with
  | { one_of = Some _; _ } | { typ = Some Object; properties = Some _; _ } | { enum = Some _; _ } ->
    let nested_type_name = concat_camelCase (List.rev ancestors) in
    let nested =
      define_type ~name:nested_type_name ~type_:(process_schema_type ~ancestors schema) ~doc:schema.description
    in
    Buffer.add_string output (nested ^ "\n");
    type_name nested_type_name
  | _ -> process_schema_type ~ancestors schema

and process_object_type ~ancestors schema =
  let is_required field_name = List.exists (String.equal field_name) schema.required in
  let make_record_field (field_name, schema_or_ref) =
    let type_ = make_type_from_schema_or_ref ~ancestors:(field_name :: ancestors) schema_or_ref in
    let record_field_name = record_field_name field_name in
    let doc =
      let content =
        match schema_or_ref with
        | Ref _ -> None
        | Obj schema -> schema.description
      in
      Option.map doc_annotation content |> Option.value ~default:""
    in
    match schema_or_ref, is_required field_name with
    | Obj { default = Some default; enum; _ }, _ ->
      sprintf "  ~%s %s <ocaml default=\"%s\">: %s;" record_field_name doc (make_atd_default_value enum default) type_
    | _, true -> sprintf "  %s %s: %s;" record_field_name doc type_
    | _, false -> sprintf "  ?%s %s: %s option;" record_field_name doc type_
  in
  match schema.properties with
  | Some properties -> sprintf "{\n%s\n}" (properties |> List.map make_record_field |> String.concat "\n")
  | None -> "json"

and make_type_from_schema_or_ref ~ancestors (schema_or_ref : schema or_ref) =
  match schema_or_ref, ancestors with
  | Obj schema, ([] | [ _ ]) -> process_schema_type ~ancestors schema
  | Obj schema, ancestors -> process_nested_schema_type ~ancestors schema
  | Ref ref_, _ -> type_name (get_ref_name ref_)

and process_one_of ~ancestors (schemas_or_refs : schema or_ref list) =
  let determine_variant_name = function
    | Ref ref_ -> variant_name (get_ref_name ref_)
    | Obj schema ->
    match (merge_all_of schema).typ with
    | Some Array -> concat_camelCase (process_array_type ~ancestors schema)
    | Some Object -> "Json"
    | _ -> variant_name (process_schema_type ~ancestors schema)
  in
  let make_one_of_variant schema_or_ref =
    let variant_name = determine_variant_name schema_or_ref in
    sprintf "  | %s of %s" variant_name
      (make_type_from_schema_or_ref ~ancestors:(variant_name :: ancestors) schema_or_ref)
  in
  let variants = List.map make_one_of_variant schemas_or_refs |> String.concat "\n" in
  sprintf "[\n%s\n] <json adapter.ocaml=\"Jsonschema2atd_runtime.Adapter.One_of\">" variants

and process_string_enums enums =
  let enums =
    List.map
      (function
        | `String s -> s
        | value ->
          failwith
            (sprintf "Invalid value %s in string enum %s" (Yojson.Basic.to_string value)
               (Yojson.Basic.to_string (`List enums))
            )
        )
      enums
  in
  let make_enum_variant value = sprintf {|  | %s <json name="%s">|} (variant_name value) value in
  let variants = List.map make_enum_variant enums |> String.concat "\n" in
  sprintf "[\n%s\n]" variants

let process_schemas (schemas : (string * schema or_ref) list) =
  List.fold_left
    (fun acc (name, schema_or_ref) ->
      let doc =
        match schema_or_ref with
        | Ref _ -> None
        | Obj schema -> schema.description
      in
      define_type ~doc ~name ~type_:(make_type_from_schema_or_ref ~ancestors:[ name ] schema_or_ref) :: acc
    )
    [] schemas

let base from =
  sprintf
    {|(* Generated by jsonschema2atd from %s *)
type json <ocaml module="Yojson.Basic" t="t"> = abstract
type int64 = int <ocaml repr="int64">
|}
    from

let make_atd_of_schemas schemas =
  input_toplevel_schemas :=
    List.filter_map
      (function
        | _name, Ref _ -> None
        | name, Obj schema -> Some (name, schema)
        )
      schemas;
  Buffer.clear output;
  Buffer.add_string output (String.concat "\n" (process_schemas schemas));
  Buffer.contents output

let make_atd_of_jsonschema ?(root = "root") input =
  let schema = Json_schema_j.schema_of_string input in
  let root_type_name = Option.value ~default:root schema.title in
  let defs =
    let defs = List.concat_map Utils.list_of_nonempty [ schema.defs; schema.definitions ] in
    List.map (fun (name, schema) -> name, Obj schema) defs
  in
  make_atd_of_schemas ([ root_type_name, Obj schema ] @ defs)

let make_atd_of_openapi ?root:_ input =
  let root = Openapi_j.root_of_string input in
  match root.components with
  | None -> failwith "components are empty"
  | Some components ->
  match components.schemas with
  | Some schemas -> make_atd_of_schemas schemas
  | None -> failwith "components schemas are empty"
