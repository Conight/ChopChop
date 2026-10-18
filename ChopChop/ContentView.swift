//
//  ContentView.swift
//  ChopChop
//
//  Created by Conight on 3/6/26.
//

import SwiftUI

struct ContentView: View {
    var updates: AppUpdateCoordinator? = nil
    var supportNavigation: AppSupportNavigation? = nil
    @StateObject var inputPresentation = DownloadInputPresentation()
    @Environment(DownloadStore.self) private var store
    var body: some View {
        DownloadConsoleView(inputCoordinator: store.inputCoordinator, updates: updates, supportNavigation: supportNavigation, inputPresentation: inputPresentation)
            .sheet(isPresented: Binding(
                get: { store.engineSetupState.requiresInstallation },
                set: { _ in }
            )) {
                EngineSetupView().environment(store)
            }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(DownloadStore())
    }
}
