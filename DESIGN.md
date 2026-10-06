# KeeLocker interface direction

## 1. Visual theme and atmosphere

KeeLocker is a calm, precise vault workspace. The sidebar feels light and alive through the native macOS sidebar material, while the item list and detail pane use quiet surface steps instead of decorative glass or heavy borders.

## 2. Color palette and roles

- Accent: `#4B63D2`, selection, primary actions, focus.
- Canvas: native `windowBackgroundColor`, detail workspace.
- List surface: native `controlBackgroundColor`, item browser.
- Sidebar surface: native `.sidebar` material, adaptive to wallpaper and appearance.
- Raised surface: native `textBackgroundColor`, grouped credential fields.
- Positive: `#2F9D68`, secure status and TOTP.
- Destructive: native system red, lock and destructive actions.

## 3. Typography rules

The app uses the macOS system typeface so controls, localization and text metrics remain genuinely native. Titles use 28 to 32 pt semibold with slightly tightened tracking; section titles use 13 pt semibold; body and controls use the system body size; metadata uses caption with secondary label color. Passwords and TOTP use the system monospaced design.

## 4. Component styling

- Sidebar rows: 38 pt high, 10 pt radius, transparent by default, subtle hover fill, accent-tinted selected fill.
- Item rows: 72 pt minimum height, 10 pt radius, no separator cage, selected and hover states use surface fills.
- Buttons: native label and icon construction, 9 pt radius for custom action buttons, 0.96 press scale in 120 ms unless Reduce Motion is enabled.
- Toolbar: standard SwiftUI toolbar items for sort and add, with system sizing, hover and pressed states. Search uses `.searchable` in the toolbar with system focus and clearing behavior.
- Credential groups: one grouped surface per semantic section, 14 pt radius, hairline separator only between rows.

## 5. Layout principles

The default window is 1180 by 760 pt. Sidebar width is 220 to 272 pt, item list width is 300 to 390 pt, and detail content has a readable 760 pt maximum. The spacing ladder is 4, 8, 12, 16, 24, 32 and 40 pt.

When the sidebar is hidden, the item list stays at least 336 pt wide so its title clears the window controls and list actions.

Sort and add stay 8 pt from the item list's trailing divider as columns resize. Search stays at the trailing edge of the window toolbar.

## 6. Depth and elevation

Depth comes from native background steps. The sidebar uses native material; toolbar controls use the system appearance, including Liquid Glass on macOS 26 and newer. The item list is one luminance step away from the detail canvas; grouped credential fields are another step. Shadows are reserved for icon tiles and high-value controls.

## 7. Do and do not

- Do keep the sidebar airy and directly scannable.
- Do use SF Symbols consistently.
- Do let macOS size native toolbar controls and preserve a 40 pt minimum hit target for custom action controls.
- Do use short, functional copy.
- Do not turn every section into an elevated card.
- Do not use gradients, ornamental glow, or thick selection rails.
- Do not animate keyboard-driven list navigation.
- Do not expose password values until the user asks.

## 8. Responsive behavior

`NavigationSplitView` supplies native column collapse and resizing. At the 980 by 680 pt minimum, the detail body tightens while action labels remain intact. At normal size, details stay left aligned within a capped reading width. All icon-only actions include accessibility labels.
