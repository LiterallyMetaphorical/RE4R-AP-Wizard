using System.ComponentModel;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Data;
using Avalonia.Data.Converters;
using Avalonia.Layout;
using Avalonia.Media;
using RE4R.AP.Launcher.ViewModels;

internal sealed class MainWindow : Window
{
    private readonly MainWindowViewModel _viewModel;
    private readonly ContentControl _screen = new();

    public MainWindow()
    {
        Title = "RE4R Archipelago Launcher";
        Width = 1080;
        Height = 780;
        MinWidth = 760;
        MinHeight = 600;

        _viewModel = new MainWindowViewModel(new AvaloniaDialogService(this));
        _viewModel.PropertyChanged += OnViewModelPropertyChanged;

        Content = new Grid
        {
            RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto"),
            Children =
            {
                Header(),
                Place(UpdateNotice(), 1),
                Place(_screen, 2),
                Place(Footer(), 3),
            },
        };

        Opened += async (_, _) =>
        {
            RenderCurrentScreen();
            await _viewModel.InitializeAsync();
            RenderCurrentScreen();
        };
        Closing += (_, e) =>
        {
            if (_viewModel.HasBusyOperation)
            {
                e.Cancel = true;
                _viewModel.Action.ErrorMessage =
                    "An operation is still running. Cancel it before closing the launcher.";
            }
        };
        Closed += (_, _) => _viewModel.Dispose();
    }

    private Control Header()
    {
        var panel = new Grid
        {
            Margin = new Thickness(28, 20),
            ColumnDefinitions = new ColumnDefinitions("*,Auto"),
        };
        panel.Children.Add(
            new StackPanel
            {
                Children =
                {
                    new TextBlock
                    {
                        Text = "RE4R AP Wizard",
                        FontSize = 26,
                        FontWeight = FontWeight.SemiBold,
                    },
                    new TextBlock
                    {
                        Text = "Resident Evil 4 Remake Archipelago setup",
                        Foreground = Brushes.Gray,
                    },
                },
            });
        var logs = CommandButton("Open Log Folder", _viewModel.OpenLogFolderCommand);
        Grid.SetColumn(logs, 1);
        panel.Children.Add(logs);
        return panel;
    }

    /// <summary>
    /// Update notice, mirroring the Windows banner. The check itself lives in
    /// the shared view-model and already ran on this platform; without this the
    /// result only ever reached the log.
    /// </summary>
    private Control UpdateNotice()
    {
        var row = new Grid
        {
            Margin = new Thickness(28, 0, 28, 4),
            ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"),
        };

        var text = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        };
        text.Bind(TextBlock.TextProperty, new Binding(nameof(MainWindowViewModel.UpdateBannerText)));
        row.Children.Add(text);

        var get = CommandButton("Get the Update", _viewModel.OpenUpdateReleaseCommand);
        get.Margin = new Thickness(12, 0, 0, 0);
        Grid.SetColumn(get, 1);
        row.Children.Add(get);

        var dismiss = CommandButton("Not Now", _viewModel.DismissUpdateCommand);
        dismiss.Margin = new Thickness(8, 0, 0, 0);
        Grid.SetColumn(dismiss, 2);
        row.Children.Add(dismiss);

        var card = Card("#1E3A5F", row);
        card.DataContext = _viewModel;
        card.Bind(IsVisibleProperty, new Binding(nameof(MainWindowViewModel.HasUpdate)));
        return card;
    }

    private Control Footer()
    {
        var panel = new StackPanel
        {
            Margin = new Thickness(28, 12, 28, 20),
            Spacing = 8,
            DataContext = _viewModel.Action,
        };
        var error = Card("#4A2020", Text("ErrorMessage", wrap: true));
        error.Bind(IsVisibleProperty, Binding("HasError"));
        panel.Children.Add(error);
        var status = Text("StatusText", wrap: true);
        status.Bind(
            IsVisibleProperty,
            new Binding("HasError") { Converter = InverseBooleanConverter.Instance });
        panel.Children.Add(status);
        return panel;
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainWindowViewModel.CurrentScreen))
        {
            RenderCurrentScreen();
        }
    }

    private void RenderCurrentScreen()
    {
        var content = _viewModel.CurrentScreen switch
        {
            SetupViewModel vm => SetupScreen(vm),
            LandingViewModel vm => LandingScreen(vm),
            ConfigureYamlViewModel vm => ConfigureScreen(vm),
            GenerationGuidanceViewModel vm => GenerationScreen(vm),
            JoinFlowViewModel vm => JoinScreen(vm),
            PatchLaunchViewModel vm => PatchScreen(vm),
            _ => new TextBlock { Text = "Loading the wizard…" },
        };

        // Pull a tagged footer out of the scrolling body and pin it to the
        // bottom, so Back and Continue sit in the same spot on every screen.
        Control? footer = null;
        if (content is Panel panel
            && panel.Children.Count > 0
            && panel.Children[^1] is Control last
            && (last.Tag as string) == FooterTag)
        {
            panel.Children.Remove(last);
            // Re-parenting drops it out of the screen panel, so it no longer
            // INHERITS that panel's DataContext. Without this the footer's
            // command bindings resolve to null and every button sits disabled,
            // which is a dead end rather than a cosmetic slip.
            last.DataContext = panel.DataContext;
            last.Margin = new Thickness(32, 8, 32, 12);
            footer = last;
        }

        var layout = new Grid { RowDefinitions = new RowDefinitions("*,Auto") };
        layout.Children.Add(new ScrollViewer { Content = content });
        if (footer is not null)
        {
            Grid.SetRow(footer, 1);
            layout.Children.Add(footer);
        }

        _screen.Content = layout;
    }

    private static Control SetupScreen(SetupViewModel vm)
    {
        var body = Screen("Setup Status", "Check the game and required components before joining.", vm);
        body.Children.Add(Field("Resident Evil 4 Remake folder", "InstallPath"));
        body.Children.Add(Row(
            Button("Browse", "BrowseCommand"),
            Button("Install REFramework", "InstallReFrameworkCommand", "ShowInstallReFrameworkButton"),
            Button("Install Archipelago Lua mod", "InstallArchipelagoLuaModCommand", "ShowInstallArchipelagoLuaModButton")));
        body.Children.Add(StatusCard("Resident Evil 4", "Re4rStatusLabel", "Re4rStatusText", "Re4rStatusBackground", "Re4rStatusForeground"));
        body.Children.Add(StatusCard("REFramework", "ReFrameworkStatusLabel", "ReFrameworkStatusText", "ReFrameworkStatusBackground", "ReFrameworkStatusForeground"));
        body.Children.Add(StatusCard("Archipelago Lua mod", "ArchipelagoLuaModStatusLabel", "ArchipelagoLuaModStatusText", "ArchipelagoLuaModStatusBackground", "ArchipelagoLuaModStatusForeground"));
        // One card, both required DLC. The underlying properties still carry the
        // Separate Ways name, but the status they report now covers Treasure
        // Map: Expansion too - see MainWindowViewModel.UpdateSeparateWaysStatus.
        body.Children.Add(StatusCard("Required DLC", "SeparateWaysStatusLabel", "SeparateWaysStatusText", "SeparateWaysStatusBackground", "SeparateWaysStatusForeground"));
        body.Children.Add(Label("BioRand game version"));
        body.Children.Add(Combo("SupportedGameVersions", "SelectedGameVersion"));
        body.Children.Add(Text("DetectedGameVersionText", true));
        body.Children.Add(Text("FingerprintSummaryText", true));
        body.Children.Add(Row(Button("Clear BioRand cache", "ClearBioRandCacheCommand"), Text("BioRandCacheText", true)));
        body.Children.Add(Footer(
            Array.Empty<Control>(),
            new[] { Primary(Button("Continue", "ContinueCommand")) }));
        return body;
    }

    private static Control LandingScreen(LandingViewModel vm)
    {
        var body = Screen("What would you like to do?", "Create or join a RE4R Archipelago multiworld.", vm);
        // BannerBackground comes from the shared view-model as a light pastel,
        // picked for the Windows light theme. Avalonia runs the dark theme, so
        // its default near-white text on that background was close to unreadable
        // - the banner has to pin its own dark foreground.
        var bannerTitle = Text("BannerTitle", true, 18);
        var bannerBody = Text("BannerBody", true);
        bannerTitle.Foreground = new SolidColorBrush(Color.Parse("#FF1A1A1A"));
        bannerTitle.FontWeight = FontWeight.SemiBold;
        bannerBody.Foreground = new SolidColorBrush(Color.Parse("#FF33302A"));
        // The banner's own buttons need the same treatment as its text: the dark
        // theme styles them light-on-light against the pastel card.
        var bannerActions = Row(
            Button("Open room", "OpenRoomPageCommand", "ShowOpenRoomPage"),
            Button("Reconnect", "ReconnectPrefillCommand", "ShowReconnectPrefill"),
            Button("Fix address", "FixAddressCommand", "ShowFixAddress"),
            Button("Re-patch", "RepatchCommand", "ShowRepatch"),
            Button("Finish patch", "FinishPatchCommand", "ShowFinishPatch"),
            Button("Retire", "RetireCommand", "ShowRetire"));
        foreach (var child in bannerActions.Children)
        {
            if (child is Button bannerButton)
            {
                bannerButton.Foreground = new SolidColorBrush(Color.Parse("#FF1A1A1A"));
                bannerButton.Background = new SolidColorBrush(Color.Parse("#FFFFFFFF"));
                bannerButton.BorderBrush = new SolidColorBrush(Color.Parse("#FFCCB98A"));
                bannerButton.BorderThickness = new Thickness(1);
            }
        }

        var banner = Card("BannerBackground",
            bannerTitle,
            bannerBody,
            bannerActions);
        banner.Bind(IsVisibleProperty, Binding("IsBannerVisible"));
        body.Children.Add(banner);
        var draft = Card("#252A31",
            Text("DraftText", true),
            Row(Button("DraftPrimaryButtonText", "DraftJoinCommand"), Button("Edit settings", "DraftEditCommand")));
        draft.Bind(IsVisibleProperty, Binding("IsDraftVisible"));
        body.Children.Add(draft);
        // Two doors, not a questionnaire. This used to be a pair of yes/no
        // stages driven by IsRoleStage and IsAddressStage; both properties were
        // removed from the shared view-model in the Windows redesign, so the
        // bindings failed, IsVisible fell back to true, and BOTH question blocks
        // rendered at once with dead buttons between them.
        var choices = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,*"),
            Margin = new Thickness(0, 6, 0, 0),
        };
        var joinChoice = BigChoice(
            "Join a Multiworld",
            "Someone gave you a room address. Connect, patch your game, and play.",
            "StartJoinCommand");
        var hostChoice = BigChoice(
            "Host a Multiworld",
            "Set the options, generate the seed, and create the room for everyone.",
            "StartCreateCommand");
        hostChoice.Margin = new Thickness(10, 0, 0, 0);
        Grid.SetColumn(hostChoice, 1);
        choices.Children.Add(joinChoice);
        choices.Children.Add(hostChoice);
        body.Children.Add(choices);
        body.Children.Add(Row(
            Button("Configure Archipelago Settings", "StartConfigureYamlCommand"),
            Button("Setup status", "OpenSetupCommand")));
        var blocking = Card("#4A3420", Text("BlockingIssuesText", true));
        blocking.Bind(IsVisibleProperty, Binding("HasBlockingIssues"));
        body.Children.Add(blocking);
        return body;
    }

    private static Control ConfigureScreen(ConfigureYamlViewModel vm)
    {
        var body = Screen("Configure Archipelago Settings", vm.HeaderDescription, vm);
        body.Children.Add(Field("Slot name", "SlotName"));
        var slotError = Text("SlotNameError", true);
        slotError.Bind(IsVisibleProperty, Binding("HasSlotNameError"));
        body.Children.Add(slotError);

        // Two columns, matching the Windows pass. Stacking every setting in one
        // narrow column wasted the whole right-hand side and pushed the YAML
        // preview off the bottom of the window.
        var left = new StackPanel { Spacing = 10 };
        left.Children.Add(Label("Difficulty"));
        left.Children.Add(Combo("DifficultyOptions", "SelectedDifficulty"));
        left.Children.Add(Label("Progression balancing"));
        left.Children.Add(Text("ProgressionBalancingLabel"));
        left.Children.Add(new Slider
        {
            Minimum = 0,
            Maximum = 99,
            [!RangeBase.ValueProperty] = Binding("ProgressionBalancing", BindingMode.TwoWay),
        });
        left.Children.Add(Label("Check guidance"));
        left.Children.Add(Combo("CheckGuidanceOptions", "SelectedCheckGuidance", "Label"));

        var right = new StackPanel { Spacing = 10, Margin = new Thickness(20, 0, 0, 0) };
        right.Children.Add(Label("Options"));
        right.Children.Add(Check("Death Link", "DeathLink"));
        right.Children.Add(Check("Allow missable locations", "AllowMissableLocations"));
        right.Children.Add(Check("Shuffle keycards", "ShuffleKeycards"));
        right.Children.Add(Check("Minimize backtracking + side areas", "MinimizeBacktracking"));
        right.Children.Add(Check("Show the in-game getting-started guide", "Tutorial"));
        right.Children.Add(Label("Typewriter locations"));
        foreach (var option in vm.TypewriterOptions)
        {
            right.Children.Add(new CheckBox
            {
                Content = option.DisplayName,
                DataContext = option,
                [!ToggleButton.IsCheckedProperty] = Binding("IsSelected", BindingMode.TwoWay),
            });
        }

        var columns = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*") };
        Grid.SetColumn(right, 1);
        columns.Children.Add(left);
        columns.Children.Add(right);
        body.Children.Add(columns);

        body.Children.Add(Label("YAML preview"));
        body.Children.Add(new TextBox
        {
            AcceptsReturn = true,
            IsReadOnly = true,
            MinHeight = 180,
            FontFamily = FontFamily.Parse("monospace"),
            [!TextBox.TextProperty] = Binding("YamlPreview"),
        });
        body.Children.Add(Text("StatusText", true));
        // Save on the left, the way forward on the right.
        body.Children.Add(Footer(
            new[] { Button("Save YAML", "SaveYamlCommand"), Button("Copy YAML", "CopyYamlCommand") },
            new[] { Button("Back", "BackToLandingCommand"), Primary(Button("Continue", "ContinueCommand")) }));
        return body;
    }

    private static Control GenerationScreen(GenerationGuidanceViewModel vm)
    {
        var body = Screen("Generate the Multiworld", "Follow the same seven organizer steps used by the Windows launcher.", vm);
        body.Children.Add(Text("StepProgressText", false, 18));
        body.Children.Add(Field("Archipelago folder", "ApInstallPath"));
        body.Children.Add(Row(
            Button("Browse", "BrowseApFolderCommand"),
            Button("Get Archipelago", "OpenApReleasePageCommand"),
            Button("Install RE4R.apworld", "CopyApworldCommand"),
            Button("Refresh", "RefreshCommand")));
        body.Children.Add(Text("ApInstallStatusText", true));
        body.Children.Add(Text("ApVersionNoteText", true));
        body.Children.Add(Text("ApworldStatusText", true));
        body.Children.Add(Row(
            Button("Configure my YAML", "ConfigureOwnYamlCommand"),
            Button("Add player YAMLs", "AddYamlsCommand"),
            Button("Add my YAML", "AddMyOwnYamlCommand"),
            Button("Copy YAMLs to Players", "CopyYamlsToPlayersCommand")));
        body.Children.Add(Text("OwnYamlStatusText", true));
        body.Children.Add(Text("YamlPanelStatusText", true));
        body.Children.Add(Text("PlayersFolderWarningText", true));
        body.Children.Add(Row(
            Button("Open Archipelago", "OpenApRootFolderCommand"),
            Button("Open Players", "OpenPlayersFolderCommand"),
            Button("Open output", "OpenOutputFolderCommand")));
        body.Children.Add(Text("OutputStatusText", true));
        body.Children.Add(Field("Room address", "RoomAddress"));
        body.Children.Add(Field("Room page URL", "RoomUrl"));
        body.Children.Add(Text("PlayersRecapText", true));
        body.Children.Add(Row(
            Button("Uploads page", "OpenUploadsPageCommand"),
            Button("Copy room summary", "CopySummaryCommand"),
            Button("Continue to Join", "ContinueToJoinCommand")));
        body.Children.Add(Footer(
            new[] { Button("Back", "BackToLandingCommand"), Button("Previous step", "BackStepCommand") },
            new[] { Primary(Button("Next step", "NextStepCommand")) }));
        return body;
    }

    private static Control JoinScreen(JoinFlowViewModel vm)
    {
        var body = Screen("Join a Multiworld", "Connect, choose BioRand options, and patch the game.", vm);
        body.Children.Add(Field("Server address", "Session.ServerAddress"));
        body.Children.Add(Field("Slot name", "Session.SlotName"));
        body.Children.Add(Field("Password (optional)", "Session.Password"));
        body.Children.Add(Field("Room page URL (optional)", "Session.RoomUrl"));
        body.Children.Add(Text("Session.WarningText", true));
        body.Children.Add(Label("Launch mode"));
        body.Children.Add(Combo("BioRandOptions.AvailableModes", "BioRandOptions.SelectedMode", "DisplayName"));
        body.Children.Add(Text("BioRandOptions.ModeStatusText", true));
        body.Children.Add(Check("Show advanced BioRand options", "BioRandOptions.ShowAdvanced"));
        body.Children.Add(BioRandOptions(vm.BioRandOptions));
        body.Children.Add(Text("StatusText", true));
        body.Children.Add(Footer(
            new[]
            {
                Button("Back", "BackToLandingCommand"),
                Button("Session details", "BackToSessionInfoCommand"),
                Button("Review options", "GoToBioRandOptionsCommand"),
            },
            new[] { Primary(Button("Patch my game", "PatchMyGameCommand")) }));
        return body;
    }

    private static Control BioRandOptions(BioRandOptionsViewModel vm)
    {
        var tabs = new TabControl();
        foreach (var page in vm.Pages)
        {
            var panel = new StackPanel { Margin = new Thickness(12), Spacing = 8 };
            foreach (var group in page.Groups)
            {
                if (group.HasTitle)
                {
                    panel.Children.Add(new TextBlock { Text = group.Title, FontSize = 17, FontWeight = FontWeight.SemiBold });
                }
                foreach (var option in group.Options)
                {
                    Control editor = option.IsSwitch
                        ? new CheckBox
                        {
                            Content = option.Label,
                            DataContext = option,
                            [!ToggleButton.IsCheckedProperty] = Binding("BoolValue", BindingMode.TwoWay),
                            [!IsEnabledProperty] = Binding("IsEnabled"),
                            [!IsVisibleProperty] = Binding("IsVisible"),
                        }
                        : new StackPanel
                        {
                            DataContext = option,
                            Orientation = Orientation.Horizontal,
                            Spacing = 8,
                            Children =
                            {
                                new TextBlock { Width = 260, [!TextBlock.TextProperty] = Binding("Label") },
                                new NumericUpDown
                                {
                                    Width = 150,
                                    Minimum = (decimal)option.Min,
                                    Maximum = (decimal)option.Max,
                                    Increment = (decimal)option.Step,
                                    [!NumericUpDown.ValueProperty] = Binding("NumberValue", BindingMode.TwoWay),
                                },
                            },
                            [!IsEnabledProperty] = Binding("IsEnabled"),
                            [!IsVisibleProperty] = Binding("IsVisible"),
                        };
                    ToolTip.SetTip(editor, option.Description);
                    panel.Children.Add(editor);
                }
            }
            tabs.Items.Add(new TabItem
            {
                Header = page.Title,
                Content = new ScrollViewer { MaxHeight = 360, Content = panel },
            });
        }
        return tabs;
    }

    private static Control PatchScreen(PatchLaunchViewModel vm)
    {
        var body = Screen("Patch and Launch", "The shared workflow reports each stage here.", vm);
        body.Children.Add(Text("Title", true, 22));
        body.Children.Add(Text("Description", true));
        foreach (var stage in vm.Stages)
        {
            var marker = new TextBlock { Width = 24, FontWeight = FontWeight.Bold };
            marker.Bind(TextBlock.TextProperty, Binding("Marker"));
            var label = new TextBlock();
            label.Bind(TextBlock.TextProperty, Binding("Label"));
            var row = new StackPanel
            {
                DataContext = stage,
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { marker, label },
            };
            body.Children.Add(row);
        }
        body.Children.Add(Text("CompletionText", true));
        body.Children.Add(Footer(
            new[] { Button("Back", "BackToLandingCommand"), Button("Cancel", "CancelCommand") },
            new[] { Primary(Button("Retry", "RetryCommand", "ShowRetry")) }));
        return body;
    }

    /// <summary>
    /// A large two-line entry point for the landing screen, matching the pair of
    /// big buttons the Windows wizard leads with.
    /// </summary>
    private static Button BigChoice(string title, string subtitle, string commandPath)
    {
        var button = new Button
        {
            Padding = new Thickness(18, 16),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Content = new StackPanel
            {
                Spacing = 6,
                Children =
                {
                    new TextBlock
                    {
                        Text = title,
                        FontSize = 20,
                        FontWeight = FontWeight.SemiBold,
                    },
                    new TextBlock
                    {
                        Text = subtitle,
                        TextWrapping = TextWrapping.Wrap,
                        Opacity = 0.75,
                    },
                },
            },
        };
        button.Bind(Avalonia.Controls.Button.CommandProperty, Binding(commandPath));
        // Its content is a panel, not text, so without this a screen reader (and
        // any automation) announces the button as "Avalonia.Controls.StackPanel".
        Avalonia.Automation.AutomationProperties.SetName(button, title);
        return button;
    }

    private static StackPanel Screen(string title, string description, object dataContext)
    {
        return new StackPanel
        {
            Margin = new Thickness(32, 16, 32, 32),
            Spacing = 12,
            DataContext = dataContext,
            Children =
            {
                new TextBlock { Text = title, FontSize = 28, FontWeight = FontWeight.SemiBold },
                new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray },
            },
        };
    }

    private static Control StatusCard(
        string title,
        string labelPath,
        string textPath,
        string backgroundPath,
        string foregroundPath)
    {
        var titleText = new TextBlock { Text = title, FontWeight = FontWeight.SemiBold };
        var labelText = Text(labelPath, true, 16);
        var statusText = Text(textPath, true);
        titleText.Bind(TextBlock.ForegroundProperty, Binding(foregroundPath));
        labelText.Bind(TextBlock.ForegroundProperty, Binding(foregroundPath));
        statusText.Bind(TextBlock.ForegroundProperty, Binding(foregroundPath));
        var card = Card(backgroundPath, titleText, labelText, statusText);
        return card;
    }

    private static Border Card(string background, params Control[] children)
    {
        var panel = new StackPanel { Spacing = 6 };
        foreach (var child in children)
        {
            panel.Children.Add(child);
        }
        var border = new Border
        {
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(6),
            Child = panel,
        };
        if (background.StartsWith('#'))
        {
            border.Background = new SolidColorBrush(Color.Parse(background));
        }
        else
        {
            border.Bind(Border.BackgroundProperty, Binding(background));
        }
        return border;
    }

    private static TextBlock Label(string value) => new() { Text = value, FontWeight = FontWeight.SemiBold };

    private static TextBlock Text(string path, bool wrap = false, double fontSize = 14)
    {
        var text = new TextBlock { TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, FontSize = fontSize };
        text.Bind(TextBlock.TextProperty, Binding(path));
        return text;
    }

    private static TextBox Field(string label, string path) =>
        new()
        {
            PlaceholderText = label,
            [!TextBox.TextProperty] = Binding(path, BindingMode.TwoWay),
        };

    private static ComboBox Combo(string itemsPath, string selectedPath, string? displayMember = null)
    {
        var combo = new ComboBox();
        combo.Bind(ItemsControl.ItemsSourceProperty, Binding(itemsPath));
        combo.Bind(ComboBox.SelectedItemProperty, Binding(selectedPath, BindingMode.TwoWay));
        if (displayMember is not null)
        {
            combo.DisplayMemberBinding = Binding(displayMember);
        }
        return combo;
    }

    private static CheckBox Check(string label, string path) =>
        new()
        {
            Content = label,
            [!ToggleButton.IsCheckedProperty] = Binding(path, BindingMode.TwoWay),
        };

    private static Button Button(string textOrPath, string commandPath, string? visiblePath = null)
    {
        var button = new Button();
        if (textOrPath.Contains("Text", StringComparison.Ordinal)
            || textOrPath.Contains("Button", StringComparison.Ordinal))
        {
            button.Bind(ContentControl.ContentProperty, Binding(textOrPath));
        }
        else
        {
            button.Content = textOrPath;
        }
        button.Bind(Avalonia.Controls.Button.CommandProperty, Binding(commandPath));
        if (visiblePath is not null)
        {
            button.Bind(IsVisibleProperty, Binding(visiblePath));
        }
        return button;
    }

    private static Button CommandButton(string label, System.Windows.Input.ICommand command) =>
        new() { Content = label, Command = command };

    /// <summary>
    /// A consistent action bar: secondary actions left, the way forward right.
    /// The Windows pass stickied this to the bottom of every screen that has a
    /// next step, so the player always knows where Continue lives.
    /// </summary>
    private static Control Footer(Control[] left, Control[] right)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
            Margin = new Thickness(0, 10, 0, 0),
        };

        var leftRow = Row(left);
        grid.Children.Add(leftRow);

        var rightRow = Row(right);
        rightRow.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(rightRow, 2);
        grid.Children.Add(rightRow);
        // Tagged so RenderCurrentScreen can lift it out of the scroll region and
        // pin it. That keeps Continue in the same place on every screen instead
        // of hiding it below a long list the player has to scroll past.
        grid.Tag = FooterTag;
        return grid;
    }

    private const string FooterTag = "screen-footer";

    /// <summary>Marks the button a player is most likely to want next.</summary>
    private static Button Primary(Button button)
    {
        button.FontWeight = FontWeight.SemiBold;
        button.Padding = new Thickness(18, 6);
        return button;
    }

    private static StackPanel Row(params Control[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var child in children)
        {
            panel.Children.Add(child);
        }
        return panel;
    }

    private static T Place<T>(T control, int row) where T : Control
    {
        Grid.SetRow(control, row);
        return control;
    }

    private static Binding Binding(string path, BindingMode mode = BindingMode.OneWay, string? stringFormat = null) =>
        new(path) { Mode = mode, StringFormat = stringFormat };

    private sealed class InverseBooleanConverter : IValueConverter
    {
        public static InverseBooleanConverter Instance { get; } = new();

        public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
            value is not true;

        public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
            throw new NotSupportedException();
    }
}
