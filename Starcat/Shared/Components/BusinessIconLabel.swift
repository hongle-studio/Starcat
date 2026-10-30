//
//  BusinessIconLabel.swift
//  Starcat
//
//  保留原生 Label 的图标列、选中着色和 labelStyle，仅替换业务图标的来源。
//

import SwiftUI

extension Label where Title == Text, Icon == BusinessIcon {
    /// 文案复用已有 Catalog key；尺寸由原调用点提供，不新增按钮或布局层级。
    @MainActor
    init(_ titleKey: LocalizedStringKey, businessIcon: BusinessIcon.Symbol, pointSize: CGFloat = 13) {
        self.init {
            Text(titleKey)
        } icon: {
            BusinessIcon(businessIcon, pointSize: pointSize)
        }
    }
}
