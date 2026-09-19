import SwiftUI

// Строка формы "Название …… 365 дней [−][+]". Тап по числу прячет кнопки и открывает
// цифровую клавиатуру — большие значения удобнее набрать, маленькие — докрутить.
struct DaysField: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...3660

    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            if editing {
                TextField("", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($focused)
                    .onChange(of: text) { _, t in
                        let digits = t.filter(\.isNumber)
                        if digits != t { text = digits }
                    }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { focused = false }
                        }
                    }
                Text(daysWord(Int(text) ?? value)).foregroundStyle(.secondary)
            } else {
                Button {
                    text = String(value)
                    editing = true
                    // фокус — после того, как TextField появится в иерархии
                    DispatchQueue.main.async { focused = true }
                } label: {
                    Text(pluralDays(value)).monospacedDigit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Stepper("", value: $value, in: range)
                    .labelsHidden()
            }
        }
    }

    private func commit() {
        if let n = Int(text) {
            value = min(max(n, range.lowerBound), range.upperBound)
        }
        editing = false
    }

    // только слово "день/дня/дней" без числа — число уже стоит в поле
    private func daysWord(_ n: Int) -> String {
        pluralDays(n).replacingOccurrences(of: String(n), with: "").trimmingCharacters(in: .whitespaces)
    }
}
