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

The detail title and its editing field share the same 30 pt semibold font, native character spacing and 42 pt minimum height, so a single-line title retains its text metrics and metadata position when entering Edit. Do not tighten only the displayed title: native macOS text fields do not honor SwiftUI tracking.

## 4. Component styling

- Vault footer: one 40 pt row below the sidebar divider, with 10 pt outer padding and 8 pt inner horizontal padding. Show a secondary 13 pt `externaldrive` symbol in a 16 pt slot and the 13 pt semibold vault name on the left, then separate Settings and Lock vault icon buttons on the right. Use 7 pt spacing, 13 pt medium action symbols in primary label color and shared 30 by 30 pt button frames with a 7 pt radius. Buttons are transparent at rest, use an 8% primary-color hover fill and a 14% pressed fill, and follow the existing press-scale/Reduce Motion behavior. Retain tooltips and accessibility labels. Keep the identity static and expose its full name through a tooltip and accessibility label; do not add an avatar tile, disclosure menu or row-wide hover/press behavior. The Settings action opens the existing settings window; Lock retains the existing leave-vault confirmation. Navigation starts with 12 pt top padding. Open another vault through File → Open Vault… (⌘O).
- Sidebar rows: vault shortcuts and group navigation share one row component: 30 pt high with 2 pt between rows, 13 pt system labels and symbols, a 16 pt icon slot and 7 pt icon-to-label spacing. Use a 10 pt radius, transparent default, subtle hover fill and accent-tinted selected fill across the full row. Unselected icons use secondary label color; selected labels use semibold. Hide zero counts throughout the sidebar and retain nonzero counts as trailing metadata.
- Group tree rows: indent each level by 12 pt and reserve an 18 pt disclosure slot even for leaves, so siblings align. Parent disclosures use an 8 pt medium chevron and an 18 by 30 pt hit area. Center the hover/pressed background in a 12 by 20 pt shape with a 4 pt radius, leaving a 3 pt gap before the folder icon slot; never extend the highlight onto the folder. Suppress the row hover fill while the pointer is in its parent disclosure slot, keeping folder pixels unchanged. Use 8%/14% primary-color fills and the existing press-scale/Reduce Motion behavior. Draw 1 pt guides at 12% primary color below each expanded parent, ending at the bottom of its visible descendants; guides are decorative and do not intercept input. Vault shortcuts do not reserve a disclosure slot.
- Item rows: 72 pt minimum height, 10 pt radius, no separator cage, selected and hover states use surface fills.
- Buttons: native label and icon construction, 9 pt radius for custom action buttons, 0.96 press scale in 120 ms unless Reduce Motion is enabled.
- Detail action bar: native SwiftUI bordered buttons at the large system control size, with a bordered prominent Copy action. macOS supplies typography, shape, padding and interaction states. Copy/Copied and Show/Hide reserve the larger label and symbol dimensions so feedback does not move the action row or the content below it.
- Detail field actions use small native bordered icon buttons; the favorite button uses the regular system control size and an orange filled star when selected. Both reserve a 16 pt symbol slot to keep changing icons from moving adjacent content; button padding and interaction states remain native.
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
- Do let macOS size native toolbar controls and preserve a 40 pt minimum hit target for standalone custom action controls. Sidebar rows, disclosure buttons and footer icon actions use the compact sizes specified above.
- Do use short, functional copy.
- Do not turn every section into an elevated card.
- Do not use gradients, ornamental glow, or thick selection rails.
- Do not animate keyboard-driven list navigation.
- Do not expose password values until the user asks.

## 8. Responsive behavior

`NavigationSplitView` supplies native column collapse and resizing. At the 980 by 680 pt minimum, the detail body tightens while action labels remain intact. At normal size, details stay left aligned within a capped reading width. All icon-only actions include accessibility labels.
