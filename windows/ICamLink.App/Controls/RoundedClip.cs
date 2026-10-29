using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ICamLink.App.Controls;

/// <summary>Clips its child to rounded corners (Border.CornerRadius does not clip child content).</summary>
public sealed class RoundedClip : Decorator
{
    public static readonly DependencyProperty RadiusProperty = DependencyProperty.Register(
        nameof(Radius), typeof(double), typeof(RoundedClip),
        new FrameworkPropertyMetadata(6.0, FrameworkPropertyMetadataOptions.AffectsArrange));

    public double Radius { get => (double)GetValue(RadiusProperty); set => SetValue(RadiusProperty, value); }

    protected override Size ArrangeOverride(Size arrangeSize)
    {
        var size = base.ArrangeOverride(arrangeSize);
        Clip = new RectangleGeometry(new Rect(size), Radius, Radius);
        return size;
    }
}
