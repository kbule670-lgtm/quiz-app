import SwiftUI

// 液态玻璃适配（iOS 26 的 Liquid Glass）
// 原理：用 Xcode 26 编译后，系统控件（标签栏/导航栏/弹窗）会自动变液态玻璃；
// 下面两个是给自定义控件用的：iOS 26+ 走真玻璃，旧系统自动回退成老样子，
// 所以最低支持版本不用动，她手机系统旧也照样能装能用。

extension View {
    /// 主要按钮：iOS 26+ 用玻璃主按钮，旧系统用原来的实心主按钮
    @ViewBuilder
    func primaryGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

/// 选项按钮的表面：没答之前 iOS 26+ 是可点的玻璃片，答完还是用颜色判对错
struct OptionSurface: ViewModifier {
    let color: Color
    let answered: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if answered {
            content
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        } else {
            content
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
