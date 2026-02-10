//
//  ContentView.swift
//  Shotify
//

//

import SwiftUI

/// Minimal content view - app runs as menu bar only
/// This view exists only for SwiftUI preview/debugging
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("Shotify")
                .font(.title)
                .fontWeight(.semibold)
            
            Text("Running in menu bar")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(width: 200, height: 150)
    }
}

#Preview {
    ContentView()
}
