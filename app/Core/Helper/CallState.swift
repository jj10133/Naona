//
//  CallState.swift
//  App
//
//  Created by Janardhan on 2026-03-22.
//

import Foundation
import SwiftUI

// MARK: - CallState

enum CallState {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
}

// MARK: - CallState helpers

extension CallState: Equatable {
    public static func == (lhs: CallState, rhs: CallState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting),
             (.connected, .connected), (.disconnected, .disconnected): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle:          return "Idle"
        case .connecting:    return "Connecting…"
        case .connected:     return "Connected"
        case .disconnected:  return "Call ended"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    var dotColor: Color {
        switch self {
        case .connected:             return .green
        case .failed, .disconnected: return .red
        default:                     return .orange
        }
    }

    var isTerminal: Bool {
        switch self {
        case .disconnected, .failed: return true
        default: return false
        }
    }
}

