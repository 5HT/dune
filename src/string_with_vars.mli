(** String with variables of the form ${...} or $(...)

    Variables cannot contain "${", "$(", ")" or "}". For instance in "$(cat ${x})", only
    "${x}" will be considered a variable, the rest is text. *)

open Import

module type S = sig
  type t
  val t : t Sexp.Of_sexp.t
  val sexp_of_t : t -> Sexp.t

  val loc : t -> Loc.t

  val of_string : loc:Loc.t -> string -> t
  val raw : loc:Loc.t -> string -> t

  val just_a_var : t -> string option

  val vars : t -> String_set.t

  val fold : t -> init:'a -> f:('a -> Loc.t -> string -> 'a) -> 'a

  val expand : t -> f:(string -> string option) -> string
end

module type Syntax = sig
  val escape : char
end

module Make(Syntax : Syntax) : S

include S
