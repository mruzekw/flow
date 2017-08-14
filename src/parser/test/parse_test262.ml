(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

type verbose_mode =
  | Quiet
  | Verbose
  | Normal

type error_reason =
  | Missing_parse_error
  | Unexpected_parse_error of (Loc.t * Parser_common.Error.t)

type test_name = string * bool (* filename * strict *)

type test_result = {
  name: test_name;
  result: (unit, error_reason) result;
}

let is_fixture =
  let suffix = "FIXTURE.js" in
  let slen = String.length suffix in
  fun filename ->
    let len = String.length filename in
    len >= slen && String.sub filename (len - slen) slen = suffix

let files_of_path path =
  let filter fn = not (is_fixture fn) in
  File_utils.fold_files ~file_only:true ~filter [path] (fun kind acc ->
    match kind with
    | File_utils.Dir _dir -> assert false
    | File_utils.File filename -> filename::acc
  ) []
  |> List.rev

module Frontmatter = struct
  type t = {
    es5id: string option;
    es6id: string option;
    esid: string option;
    flags: strictness;
    negative: negative option;
  }
  and negative = {
    phase: string;
    type_: string;
  }
  and strictness =
    | Raw
    | Only_strict
    | No_strict
    | Both_strictnesses

  let of_string =
    let start_regexp = Str.regexp "/\\*---" in
    let end_regexp = Str.regexp "---\\*/" in
    let cr_regexp = Str.regexp "\r\n?" in
    let es5id_regexp = Str.regexp "^ *es5id: *\\(.*\\)" in
    let es6id_regexp = Str.regexp "^ *es6id: *\\(.*\\)" in
    let esid_regexp = Str.regexp "^ *esid: *\\(.*\\)" in
    let flags_regexp = Str.regexp "^ *flags: *\\[\\(.*\\)\\]" in
    let only_strict_regexp = Str.regexp_string "onlyStrict" in
    let no_strict_regexp = Str.regexp_string "noStrict" in
    let raw_regexp = Str.regexp_string "raw" in
    let negative_regexp = Str.regexp "^ *negative:$" in
    let type_regexp = Str.regexp "^ +type: *\\(.*\\)" in
    let phase_regexp = Str.regexp "^ +phase: *\\(.*\\)" in
    let matched_group regex str =
      let _ = Str.search_forward regex str 0 in
      Str.matched_group 1 str
    in
    let opt_matched_group regex str =
      try Some (matched_group regex str) with Not_found -> None
    in
    let contains needle haystack =
      try
        let _ = Str.search_forward needle haystack 0 in
        true
      with Not_found -> false
    in
    fun source ->
      try
        let start_idx = (Str.search_forward start_regexp source 0) + 5 in
        let end_idx = Str.search_forward end_regexp source start_idx in
        let text = String.sub source start_idx (end_idx - start_idx) in
        let text = Str.global_replace cr_regexp "\n" text in
        let es5id = opt_matched_group es5id_regexp text in
        let es6id = opt_matched_group es6id_regexp text in
        let esid = opt_matched_group esid_regexp text in
        let flags =
          match opt_matched_group flags_regexp text with
          | Some flags ->
            let only_strict = contains only_strict_regexp flags in
            let no_strict = contains no_strict_regexp flags in
            let raw = contains raw_regexp flags in
            begin match only_strict, no_strict, raw with
            | true, false, false -> Only_strict
            | false, true, false -> No_strict
            | false, false, true -> Raw
            | _ -> Both_strictnesses (* validate other nonsense combos? *)
            end
          | None -> Both_strictnesses
        in
        let negative =
          if contains negative_regexp text then
            Some {
              phase = matched_group phase_regexp text;
              type_ = matched_group type_regexp text;
            }
          else None
        in
        Some {
          es5id;
          es6id;
          esid;
          flags;
          negative;
        }
      with Not_found ->
        None

  let to_string fm =
    let opt_cons key x acc =
      match x with
      | Some x -> (Printf.sprintf "%s: %s" key x)::acc
      | None -> acc
    in
    []
    |> opt_cons "es5id" fm.es5id
    |> opt_cons "es6id" fm.es6id
    |> opt_cons "esid" fm.esid
    |> (fun acc ->
          let flags = match fm.flags with
          | Only_strict -> Some "onlyStrict"
          | No_strict -> Some "noStrict"
          | Raw -> Some "raw"
          | Both_strictnesses -> None
          in
          match flags with
          | Some flags ->
            (Printf.sprintf "flags: [%s]" flags)::acc
          | None ->
            acc
       )
    |> List.rev
    |> String.concat "\n"

  let negative_phase fm =
    match fm.negative with
    | Some { phase; _ } -> Some phase
    | None -> None
end

let options_by_strictness frontmatter =
  let open Parser_env in
  let open Frontmatter in
  let o = Parser_env.default_parse_options in
  match frontmatter.flags with
  | Both_strictnesses ->
    failwith "should have been split by split_by_strictness"
  | Only_strict ->
    { o with use_strict = true }
  | No_strict
  | Raw ->
    { o with use_strict = false }

let split_by_strictness frontmatter =
  let open Frontmatter in
  match frontmatter.flags with
  | Both_strictnesses ->
    [
      { frontmatter with flags = Only_strict };
      { frontmatter with flags = No_strict };
    ]
  | Only_strict
  | No_strict
  | Raw ->
    [frontmatter]

let parse_test acc filename =
  let content = Sys_utils.cat filename in
  match Frontmatter.of_string content with
  | Some frontmatter ->
    List.fold_left (fun acc frontmatter ->
      let input = (filename, Frontmatter.(frontmatter.flags = Only_strict)) in
      (input, frontmatter, content)::acc
    ) acc (split_by_strictness frontmatter)
  | None ->
    acc

let run_test (name, frontmatter, content) =
  let (filename, use_strict) = name in
  let parse_options = Parser_env.({ default_parse_options with use_strict }) in
  let (_ast, errors) = Parser_flow.program_file
    ~fail:false ~parse_options:(Some parse_options)
    content (Some (Loc.SourceFile filename)) in
  let result = match errors, Frontmatter.negative_phase frontmatter with
  | [], Some "early" ->
    (* expected a parse error, didn't get it *)
    Error Missing_parse_error
  | _, Some "early" ->
    (* expected a parse error, got one *)
    Ok ()
  | [], Some _
  | [], None ->
    (* did not expect a parse error, didn't get one *)
    Ok ()
  | err::_, Some _
  | err::_, None ->
    (* did not expect a parse error, got one incorrectly *)
    Error (Unexpected_parse_error err)
  in
  { name; result }

let print_error ~strip_root (filename, use_strict) err =
  let filename = match strip_root with
  | Some root ->
    let len = String.length root in
    String.sub filename len (String.length filename - len)
  | None -> filename
  in
  let strict = if use_strict then "(strict mode)" else "(default)" in
  let cr = if Unix.isatty Unix.stdout then "\r" else "" in
  match err with
  | Missing_parse_error ->
    Printf.printf "%s%s %s\n  Missing parse error\n%!" cr filename strict
  | Unexpected_parse_error (loc, err) ->
    Printf.printf "%s%s %s\n  %s at %s\n%!"
      cr filename strict (Parse_error.PP.error err) (Loc.to_string loc)

module Progress_bar = struct
  type t = {
    mutable count: int;
    mutable last_update: float;
    total: int;
    chunks: int;
    frequency: float;
  }

  let percentage bar =
    Printf.sprintf "%3d%%" (bar.count * 100 / bar.total)

  let meter bar =
    let chunks = bar.chunks in
    let c = bar.count * chunks / bar.total in
    if c = 0 then String.make chunks ' '
    else if c = chunks then String.make chunks '='
    else (String.make (c - 1) '=')^">"^(String.make (chunks - c) ' ')

  let incr bar =
    bar.count <- succ bar.count

  let print (passed, failed) bar =
    let total = float_of_int (passed + failed) in
    Printf.printf "\r%s [%s] %d/%d -- Passed: %d (%.2f%%), Failed: %d (%.2f%%)%!"
      (percentage bar) (meter bar) bar.count bar.total
      passed ((float_of_int passed) /. total *. 100.)
      failed ((float_of_int failed) /. total *. 100.)

  let print_throttled (passed, failed) bar =
    let now = Unix.gettimeofday () in
    if now -. bar.last_update > bar.frequency then begin
      bar.last_update <- now;
      print (passed, failed) bar
    end

  let print_final (passed, failed) bar =
    print (passed, failed) bar;
    Printf.printf "\n%!"

  let make ~chunks ~frequency total =
    {
      count = 0;
      last_update = 0.;
      total;
      chunks;
      frequency;
    }
end

let main () =
  let verbose_ref = ref Normal in
  let path_ref = ref None in
  let strip_root_ref = ref false in
  let speclist = [
    "-q", Arg.Unit (fun () -> verbose_ref := Quiet), "Enables quiet mode";
    "-v", Arg.Unit (fun () -> verbose_ref := Verbose), "Enables verbose mode";
    "-s", Arg.Set strip_root_ref, "Print paths relative to root directory";
  ] in
  let usage_msg = "Runs flow parser on test262 tests. Options available:" in
  Arg.parse speclist (fun anon -> path_ref := Some anon) usage_msg;
  let path = match !path_ref with
  | Some ""
  | None -> prerr_endline "Invalid usage"; exit 1
  | Some path -> if path.[String.length path - 1] <> '/' then (path^"/") else path
  in
  let strip_root = if !strip_root_ref then Some path else None in
  let quiet = !verbose_ref = Quiet in
  let _verbose = !verbose_ref = Verbose in

  let files = files_of_path path |> List.sort String.compare in
  let tests = List.fold_left parse_test [] files |> List.rev in
  let test_count = List.length tests in

  let bar =
    if quiet || not (Unix.isatty Unix.stdout) then None
    else Some (Progress_bar.make ~chunks:40 ~frequency:0.1 test_count) in

  let (passed, failed) = List.fold_left (fun (passed_acc, failed_acc) test ->
    let (passed, failed) =
      let { name; result } = run_test test in
      match result with
      | Ok _ -> (1, 0)
      | Error err ->
        print_error ~strip_root name err;
        (0, 1)
    in
    let acc = (passed_acc + passed, failed_acc + failed) in
    Option.iter ~f:(fun bar ->
      Progress_bar.incr bar;
      if failed > 0 then Progress_bar.print acc bar
      else Progress_bar.print_throttled acc bar
    ) bar;
    acc
  ) (0, 0) tests in

  begin match bar with
  | Some bar -> Progress_bar.print_final (passed, failed) bar
  | None ->
      let total = float_of_int (passed + failed) in
      Printf.printf "=== Summary ===\n";
      Printf.printf "Passed: %d (%.2f%%)\n" passed ((float_of_int passed) /. total *. 100.);
      Printf.printf "Failed: %d (%.2f%%)\n" failed ((float_of_int failed) /. total *. 100.)
  end;

  ()

let () = main ()
