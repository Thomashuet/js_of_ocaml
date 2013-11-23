(* Js_of_ocaml toplevel
 * http://www.ocsigen.org/js_of_ocaml/
 * Copyright (C) 2011 Jérôme Vouillon
 * Laboratoire PPS - CNRS Université Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(*
TODO
- different style for toplevel input, output and errors
  in particular, the prompt should not be part of the text
  (CSS generated content)
- syntax highlighting?
*)

open Compiler

let split_primitives p =
  let len = String.length p in
  let rec split beg cur =
    if cur >= len then []
    else if p.[cur] = '\000' then
      String.sub p beg (cur - beg) :: split (cur + 1) (cur + 1)
    else
      split beg (cur + 1) in
  Array.of_list(split 0 0)

(****)

class type global_data = object
  method toc : (string * string) list Js.readonly_prop
  method compile : (string -> string) Js.writeonly_prop
end

external global_data : unit -> global_data Js.t = "caml_get_global_data"

let g = global_data ()

let _ =
  let toc = g##toc in
  let prims = split_primitives (List.assoc "PRIM" toc) in
  let compile s =
    let output_program = Driver.from_string prims s in
    let b = Buffer.create 100 in
    output_program (Pretty_print.to_buffer b);
    Buffer.contents b
  in
  g##compile <- compile (*XXX HACK!*)

let start ppf = begin
  Format.fprintf ppf "        OCaml version %s@.@." Sys.ocaml_version;
  Toploop.initialize_toplevel_env ();
  Toploop.input_name := ""
end

let at_bol = ref true
let consume_nl = ref false

let refill_lexbuf s p ppf buffer len =
  if !consume_nl then begin
    let l = String.length s in
    if (!p < l && s.[!p] = '\n') then
      incr p
    else if (!p + 1 < l && s.[!p] = '\r' && s.[!p + 1] = '\n') then
      p := !p + 2;
    consume_nl := false
  end;
  if !p = String.length s then
    0
  else begin
    let c = s.[!p] in
    incr p;
    buffer.[0] <- c;
    if !at_bol then Format.fprintf ppf "# ";
    at_bol := (c = '\n');
    if c = '\n' then
      Format.fprintf ppf "@."
    else
      Format.fprintf ppf "%c" c;
    1
  end

let ensure_at_bol ppf =
  if not !at_bol then begin
    Format.fprintf ppf "@.";
    consume_nl := true; at_bol := true
  end

let loop s ppf =
  let lb = Lexing.from_function (refill_lexbuf s (ref 0) ppf) in
  begin try
    while true do
      try
        let phr = !Toploop.parse_toplevel_phrase lb in
        ensure_at_bol ppf;
        ignore(Toploop.execute_phrase true ppf phr)
      with
        End_of_file ->
          raise End_of_file
      | x ->
          ensure_at_bol ppf;
          Errors.report_error ppf x
    done
  with End_of_file ->
    ()
  end

let postMessage = Js.Unsafe.variable "postMessage"

let js_object = Js.Unsafe.variable "Object"

let update_prompt prompt =
  let response = jsnew js_object () in
  ignore begin
    Js.Unsafe.set response (Js.string "ready") (Js.string prompt);
    Js.Unsafe.call postMessage (Js.Unsafe.variable "self") [|Js.Unsafe.inject response|]
  end

let post_output s =
  let response = jsnew js_object () in
  ignore begin
    Js.Unsafe.set response (Js.string "out") (Js.string s);
    Js.Unsafe.call postMessage (Js.Unsafe.variable "self") [|Js.Unsafe.inject response|]
  end

let run () =
  let ppf =
    let b = Buffer.create 80 in
    Format.make_formatter
      (fun s i l -> Buffer.add_substring b s i l)
      (fun _ ->
         post_output (Buffer.contents b);
         Buffer.clear b)
  in
  let onmessage event =
    let s = Js.to_string event##data##input in
    loop s ppf
  in
  let _ = Js.Unsafe.set (Js.Unsafe.variable "self") (Js.string "onmessage") onmessage in
  start ppf


let _ = run ()
