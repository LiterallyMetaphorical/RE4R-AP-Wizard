"""Static audit: does every themed surface actually resolve from the palette?

Checks four things without running the app:
  1. every control type the markup instantiates has a themed implicit style
     (or is a layout element with no painted chrome of its own)
  2. no raw colour literal survives in the XAML or the shared view models
  3. the two dictionaries expose identical keys and styled types
  4. every keyed Button/TextBlock style inherits the implicit one, or it
     silently falls back to WPF's light default chrome
"""
import io, os, re, glob

ROOT = r"S:\Programs\GitHub\RE4R-AP-Launcher\src\RE4R.AP.Launcher"
VIEWS = glob.glob(os.path.join(ROOT, "Views", "*.xaml"))
THEMES = {n: io.open(os.path.join(ROOT, "Themes", n), encoding="utf-8").read()
          for n in ("Light.xaml", "Dark.xaml")}

# Layout-only or content elements that paint nothing themselves.
UNPAINTED = {
    "Grid", "StackPanel", "DockPanel", "WrapPanel", "Border", "Run",
    "RowDefinition", "ColumnDefinition", "Setter", "Style", "Trigger",
    "DataTrigger", "DataTemplate", "ControlTemplate", "ItemsPanelTemplate",
    "ItemsControl", "ContentPresenter", "ContentControl", "Window",
    "BooleanToVisibilityConverter", "InverseBooleanToVisibilityConverter",
    "ThemeBrushConverter", "Setter.Value", "Style.Triggers", "Grid.RowDefinitions",
    "ItemsPresenter",
    "Grid.ColumnDefinitions", "UniformGrid", "Path", "Ellipse", "Rectangle",
    "Viewbox", "Canvas", "Separator", "Image", "Line", "Polygon",
    # Brush primitives, not controls: they ARE the colour, so there is nothing
    # to theme them with.
    "LinearGradientBrush", "RadialGradientBrush", "GradientStop", "SolidColorBrush",
    # Not a control: a column DESCRIPTOR. The cells it generates are
    # DataGridCell, which is styled, and the TextBlock inside inherits that
    # cell's Foreground. There is no element here to give a style to.
    "DataGridTextColumn",
    # Deliberately NOT given an implicit style. The only ToggleButton the app
    # instantiates is the theme switch, which is fully re-templated by
    # ThemeSwitchStyle - and an implicit ToggleButton style would leak into the
    # ToggleButton inside every ComboBox and DataGrid header, breaking controls
    # this change is supposed to be fixing.
    "ToggleButton",
}

failures = []

def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else " -> " + detail))
    if not ok:
        failures.append(name)

print("== 1. every painted control type has a themed style ==")
styled = set(re.findall(r'TargetType="(?:dgp:)?([A-Za-z]+)"', THEMES["Dark.xaml"]))
used = set()
for path in VIEWS:
    s = io.open(path, encoding="utf-8").read()
    used |= set(re.findall(r'<([A-Z][A-Za-z]+)[\s/>]', s))
painted = {t for t in used if t not in UNPAINTED}
missing = sorted(t for t in painted if t not in styled)
check("no painted control type is unstyled", not missing, ", ".join(missing))
print("       styled: " + ", ".join(sorted(styled)))

print("== 2. no raw colour literals left ==")
for path in VIEWS:
    s = io.open(path, encoding="utf-8").read()
    raw = re.findall(
        r'(?:Foreground|Background|BorderBrush|CaretBrush)="((?:#[0-9A-Fa-f]{3,8})|White|Black|DimGray|Gray|LightGray)"', s)
    raw += re.findall(
        r'Property="(?:Foreground|Background|BorderBrush)" Value="((?:#[0-9A-Fa-f]{3,8})|White|Black|DimGray|Gray)"', s)
    check(f"{os.path.basename(path)} has no hardcoded brush", not raw, ", ".join(sorted(set(raw))))

for vm in ("LandingViewModel.cs", "SetupViewModel.cs", "ActionViewModel.cs"):
    s = io.open(os.path.join(ROOT, "ViewModels", vm), encoding="utf-8").read()
    raw = re.findall(r'"(#[0-9A-Fa-f]{6,8})"', s)
    check(f"{vm} emits tokens, not colours", not raw, ", ".join(raw))

print("== 3. the two dictionaries agree ==")
lk = set(re.findall(r'x:Key="([^"]+)"', THEMES["Light.xaml"]))
dk = set(re.findall(r'x:Key="([^"]+)"', THEMES["Dark.xaml"]))
check("identical resource keys", lk == dk, str(lk ^ dk))
lt = set(re.findall(r'TargetType="([^"]+)"', THEMES["Light.xaml"]))
dt = set(re.findall(r'TargetType="([^"]+)"', THEMES["Dark.xaml"]))
check("identical styled types", lt == dt, str(lt ^ dt))

print("== 4. every token a view model names exists in both themes ==")
vm_tokens = set()
for vm in ("LandingViewModel.cs", "SetupViewModel.cs", "ActionViewModel.cs"):
    s = io.open(os.path.join(ROOT, "ViewModels", vm), encoding="utf-8").read()
    vm_tokens |= set(re.findall(r'=\s*"([A-Za-z]+Brush)"', s))
unknown = sorted(t for t in vm_tokens if t not in lk)
check("view-model tokens all resolve", not unknown, ", ".join(unknown))
print("       tokens used: " + ", ".join(sorted(vm_tokens)))

print("== 5. every Button/TextBlock style inherits the themed default ==")
# Keyed AND anonymous. An inline <Style TargetType="Button"> inside a
# DataTemplate is just as capable of dropping back to WPF's light chrome, and
# missing those is exactly how the footer buttons stayed pale.
for path in VIEWS:
    s = io.open(path, encoding="utf-8").read()
    for m in re.finditer(r'<Style ([^>]*?)TargetType="(Button|TextBlock|ToggleButton)"([^>]*)>', s):
        before, ttype, rest = m.groups()
        attrs = before + rest
        if ttype == "ToggleButton":
            continue  # fully re-templated by ThemeSwitchStyle, inherits nothing by design
        keyed = re.search(r'x:Key="([^"]+)"', attrs)
        label = keyed.group(1) if keyed else f"anonymous {ttype} style"
        check(f"{label} has BasedOn", "BasedOn" in attrs,
              "would fall back to WPF's light default chrome")

print("== 6. the popup surfaces are overridden ==")
for needed in ("WindowBrushKey", "MenuBrushKey", "InfoBrushKey", "HighlightBrushKey",
               "GrayTextBrushKey", "ControlBrushKey"):
    check(f"SystemColors.{needed} overridden",
          all(needed in t for t in THEMES.values()))

print()
print(f"{len(failures)} failure(s)" if failures else "all checks passed")
raise SystemExit(1 if failures else 0)
