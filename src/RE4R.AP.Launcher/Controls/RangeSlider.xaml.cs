using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace RE4R.AP.Launcher.Controls;

/// <summary>
/// One track with two markers over a small run of whole numbers: the player
/// sets where a range starts and where it ends. Built for Ranks as Checks,
/// where the steps are the six Mercenaries ranks, so it snaps to every step
/// and draws the step names underneath rather than raw numbers.
///
/// Two ordinary Sliders would have meant two tracks, which reads as two
/// separate settings rather than one span (Cam, 2026-09-06).
/// </summary>
public partial class RangeSlider : UserControl
{
    private const double ThumbSize = 16.0;

    public RangeSlider()
    {
        InitializeComponent();
        SizeChanged += (_, _) => UpdateVisual();
        Loaded += (_, _) => UpdateVisual();
    }

    public static readonly DependencyProperty MinimumProperty = DependencyProperty.Register(
        nameof(Minimum), typeof(int), typeof(RangeSlider),
        new FrameworkPropertyMetadata(0, OnRangePropertyChanged));

    public static readonly DependencyProperty MaximumProperty = DependencyProperty.Register(
        nameof(Maximum), typeof(int), typeof(RangeSlider),
        new FrameworkPropertyMetadata(5, OnRangePropertyChanged));

    public static readonly DependencyProperty LowerValueProperty = DependencyProperty.Register(
        nameof(LowerValue), typeof(int), typeof(RangeSlider),
        new FrameworkPropertyMetadata(0,
            FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, OnRangePropertyChanged));

    public static readonly DependencyProperty UpperValueProperty = DependencyProperty.Register(
        nameof(UpperValue), typeof(int), typeof(RangeSlider),
        new FrameworkPropertyMetadata(0,
            FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, OnRangePropertyChanged));

    public static readonly DependencyProperty StepLabelsProperty = DependencyProperty.Register(
        nameof(StepLabels), typeof(IReadOnlyList<string>), typeof(RangeSlider),
        new FrameworkPropertyMetadata(null, OnRangePropertyChanged));

    public int Minimum
    {
        get => (int)GetValue(MinimumProperty);
        set => SetValue(MinimumProperty, value);
    }

    public int Maximum
    {
        get => (int)GetValue(MaximumProperty);
        set => SetValue(MaximumProperty, value);
    }

    /// <summary>Where the range starts. Never above <see cref="UpperValue"/>.</summary>
    public int LowerValue
    {
        get => (int)GetValue(LowerValueProperty);
        set => SetValue(LowerValueProperty, value);
    }

    /// <summary>Where the range ends. Never below <see cref="LowerValue"/>.</summary>
    public int UpperValue
    {
        get => (int)GetValue(UpperValueProperty);
        set => SetValue(UpperValueProperty, value);
    }

    /// <summary>One name per step, drawn under the track. Numbers are used if this is unset.</summary>
    public IReadOnlyList<string>? StepLabels
    {
        get => (IReadOnlyList<string>?)GetValue(StepLabelsProperty);
        set => SetValue(StepLabelsProperty, value);
    }

    private static void OnRangePropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is RangeSlider slider)
        {
            slider.UpdateVisual();
        }
    }

    private int StepCount => Math.Max(1, Maximum - Minimum);

    /// <summary>Pixels between the centre of the first marker and the last.</summary>
    private double UsableWidth => Math.Max(1.0, TrackCanvas.ActualWidth - ThumbSize);

    private double CentreFor(int value)
    {
        var clamped = Math.Clamp(value, Minimum, Maximum);
        return (ThumbSize / 2.0) + ((clamped - Minimum) / (double)StepCount * UsableWidth);
    }

    private int ValueAt(double centre)
    {
        var fraction = (centre - (ThumbSize / 2.0)) / UsableWidth;
        var raw = Minimum + (fraction * StepCount);
        return Math.Clamp((int)Math.Round(raw, MidpointRounding.AwayFromZero), Minimum, Maximum);
    }

    private void UpdateVisual()
    {
        if (TrackCanvas is null || !IsLoaded)
        {
            return;
        }

        var lower = Math.Clamp(Math.Min(LowerValue, UpperValue), Minimum, Maximum);
        var upper = Math.Clamp(Math.Max(LowerValue, UpperValue), Minimum, Maximum);
        var midY = (TrackCanvas.ActualHeight - 4.0) / 2.0;
        var thumbY = (TrackCanvas.ActualHeight - ThumbSize) / 2.0;

        TrackRail.Width = Math.Max(0.0, TrackCanvas.ActualWidth - ThumbSize);
        Canvas.SetLeft(TrackRail, ThumbSize / 2.0);
        Canvas.SetTop(TrackRail, midY);

        var lowerCentre = CentreFor(lower);
        var upperCentre = CentreFor(upper);
        TrackFill.Width = Math.Max(0.0, upperCentre - lowerCentre);
        Canvas.SetLeft(TrackFill, lowerCentre);
        Canvas.SetTop(TrackFill, midY);

        Canvas.SetLeft(LowerThumb, lowerCentre - (ThumbSize / 2.0));
        Canvas.SetTop(LowerThumb, thumbY);
        Canvas.SetLeft(UpperThumb, upperCentre - (ThumbSize / 2.0));
        Canvas.SetTop(UpperThumb, thumbY);

        RebuildLabels(lower, upper);
    }

    private void RebuildLabels(int lower, int upper)
    {
        LabelCanvas.Children.Clear();
        for (var value = Minimum; value <= Maximum; value++)
        {
            var index = value - Minimum;
            var text = StepLabels is { Count: > 0 } && index < StepLabels.Count
                ? StepLabels[index]
                : value.ToString();
            var inRange = value >= lower && value <= upper;
            var label = new TextBlock
            {
                Text = text,
                FontSize = 11,
                Opacity = inRange ? 1.0 : 0.5,
                FontWeight = inRange ? FontWeights.SemiBold : FontWeights.Normal,
            };
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(label, CentreFor(value) - (label.DesiredSize.Width / 2.0));
            Canvas.SetTop(label, 2.0);
            LabelCanvas.Children.Add(label);
        }
    }

    private void OnLowerThumbDragged(object sender, DragDeltaEventArgs e) =>
        MoveThumb(isLower: true, e.HorizontalChange);

    private void OnUpperThumbDragged(object sender, DragDeltaEventArgs e) =>
        MoveThumb(isLower: false, e.HorizontalChange);

    private void MoveThumb(bool isLower, double horizontalChange)
    {
        var current = isLower ? LowerValue : UpperValue;
        var moved = ValueAt(CentreFor(current) + horizontalChange);
        if (moved == current)
        {
            return;
        }

        // A marker pushed past its partner carries it along rather than
        // stopping dead, which is how the range reads when you drag it.
        if (isLower)
        {
            LowerValue = moved;
            if (moved > UpperValue)
            {
                UpperValue = moved;
            }
        }
        else
        {
            UpperValue = moved;
            if (moved < LowerValue)
            {
                LowerValue = moved;
            }
        }
    }

    /// <summary>Clicking the track moves whichever marker is nearer.</summary>
    private void OnTrackClicked(object sender, MouseButtonEventArgs e)
    {
        var clicked = ValueAt(e.GetPosition(TrackCanvas).X);
        var toLower = Math.Abs(clicked - LowerValue);
        var toUpper = Math.Abs(clicked - UpperValue);
        if (toLower < toUpper || (toLower == toUpper && clicked < LowerValue))
        {
            LowerValue = Math.Min(clicked, UpperValue);
        }
        else
        {
            UpperValue = Math.Max(clicked, LowerValue);
        }
    }
}
