//
//  ContentView.swift
//  ChopChop
//
//  Created by Conight on 3/6/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: DownloadStore
    var body: some View {
        DownloadConsoleView(inputCoordinator: store.inputCoordinator)
            .sheet(isPresented: Binding(
                get: { store.engineSetupState.requiresInstallation },
                set: { _ in }
            )) {
                EngineSetupView().environmentObject(store)
            }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(DownloadStore())
    }
}
