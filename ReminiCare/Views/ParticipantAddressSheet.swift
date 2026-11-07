import ReminiCareKit
import SwiftUI

struct ParticipantAddressSheet: View {
    let initial: ParticipantAddress
    let onSave: (ParticipantAddress) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var surname = ""
    @State private var title = "長輩"
    @State private var showCommon = false

    private var candidates: [String] {
        var list = ParticipantAddress.candidates(for: initial.surname)
        if showCommon {
            for name in ParticipantAddress.commonSurnames where !list.contains(name) { list.append(name) }
        }
        return list
    }

    private var address: ParticipantAddress {
        ParticipantAddress(surname.trimmingCharacters(in: .whitespaces), title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("請選擇正確姓氏，或直接輸入。候選不代表自動判定。") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                        ForEach(candidates, id: \.self) { name in
                            Button(name) { surname = name }
                                .font(.system(size: 26))
                                .frame(minWidth: 60, minHeight: 52)
                                .background(surname == name ? Theme.yellow : Theme.languagePill, in: RoundedRectangle(cornerRadius: 12))
                                .buttonStyle(.plain)
                        }
                    }
                    Button(showCommon ? "收起姓氏表" : "更多姓氏") { showCommon.toggle() }.font(.system(size: 22))
                    TextField("姓氏（不含名字）", text: $surname)
                        .font(.system(size: 26))
                    if !surname.isEmpty && !address.isValid {
                        Text("請輸入 1–4 個中文字的姓氏，不要包含稱謂").foregroundStyle(.red)
                    }
                }
                Section("稱謂") {
                    Picker("稱謂", selection: $title) {
                        ForEach(ParticipantAddress.titles, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.wheel)
                }
            }
            .navigationTitle("修改稱呼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("確認") {
                        onSave(address)
                        dismiss()
                    }
                    .disabled(!address.isValid)
                }
            }
        }
        .onAppear {
            surname = initial.surname
            title = initial.title
        }
    }
}
