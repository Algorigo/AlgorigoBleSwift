//
//  File.swift
//  AlgorigoBleLibrary
//
//  Created by Jaehong Yoo on 2023/02/01.
//  Copyright © 2023 Jaehong Yoo. All rights reserved.
//

import Foundation

extension Array {
    func unique<T : Hashable>(by: ((Element) -> (T)))  -> [Element] {
        var set = Set<T>() //the unique list kept in a Set for fast retrieval
        var arrayOrdered = [Element]() //keeping the unique list of elements but ordered
        for value in self {
            if !set.contains(by(value)) {
                set.insert(by(value))
                arrayOrdered.append(value)
            }
        }

        return arrayOrdered
    }
}
