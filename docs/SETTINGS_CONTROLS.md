# Settings controls

For native HushType settings, related parameters belong in a titled
`SettingsFeatureGroup` that is collapsed by default. Expanding the group keeps
its existing sliders, toggles, pickers, and other controls intact; it does not
turn every picker into a menu.

Use a feature group when a named setting area has multiple controls, such as
recognition output, history retention, or an engine's configuration. Keep
overview/status, active runtime controls, and model lists directly visible.
Existing `DisclosureGroup`s keep their own expansion behavior. Picker styles
remain chosen for the control and context already present in the view.
