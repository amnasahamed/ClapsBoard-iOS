//
//  Diagnostics.swift
//  ClapsBoard
//
//  Debug-only diagnostic output.
//

import Foundation

func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let output = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
#endif
}
