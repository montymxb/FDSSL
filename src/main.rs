mod syntax;
mod parser;

use syntax::Expr::{DefMut, Vect, I};
use syntax::Type::{Int, Array};
use parser::program;

fn main() {
    let prog = "\
    laksjd (a: tru, b: a) -> (a, b) { \
    kjsd {{{{}{pd{kdfj}kjd} }}}} {} {}";
    let res = match program(prog) {
        Ok((_, a)) => a,
        _          => "Error: Not a function",
    };
    println!("{}", res);

//     let x = DefMut {
//         name: "x".to_string(),
//         value: Box::new(
//             Vect {
//                 is_matrix: false,
//                 datatype: Array(Box::new(Int)),
//                 value: vec!{
//                     Box::new(I(1)), Box::new(I(2))
//                 }
//             }
//         ),
//     };
}
