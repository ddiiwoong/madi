using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace Madi;

/// <summary>
/// 도구 ▸ LLM 키… — 서비스마다 키를 두고(자격 증명 관리자, <see cref="CredentialStore"/>) 확인한다. macOS판 설정 ▸ LLM과 같은 일:
/// <b>문서는 보내지 않는다</b>. 확인은 그 서비스에 모델 목록만 묻고, 결과 한 줄을 적는다.
/// </summary>
public sealed class LlmKeysWindow : Window
{
    private readonly ComboBox service = new() { MinWidth = 220 };
    private readonly PasswordBox key = new() { MinWidth = 320 };
    private readonly TextBox region = new() { MinWidth = 120 };
    private readonly TextBlock source = new() { Margin = new Thickness(0, 4, 0, 0) };
    private readonly TextBlock stored = new() { Margin = new Thickness(0, 4, 0, 0) };
    private readonly TextBlock result = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0), MinHeight = 36 };
    private readonly Label regionLabel = new() { Content = "리전(_G)", Padding = new Thickness(0, 0, 8, 0) };

    public LlmKeysWindow(Window owner)
    {
        Owner = owner;
        Title = "LLM 키 - 마디";
        SizeToContent = SizeToContent.WidthAndHeight;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        foreach (var item in LlmServices.All) service.Items.Add(new ComboBoxItem { Content = item.DisplayName(), Tag = item });
        service.SelectedIndex = 0;
        service.SelectionChanged += (_, _) => Refresh();

        var grid = new Grid { Margin = new Thickness(16) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        void Row(int index, UIElement label, UIElement field)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(label, index);
            Grid.SetRow(field, index);
            Grid.SetColumn(field, 1);
            grid.Children.Add(label);
            grid.Children.Add(field);
        }
        Label Caption(string text, Control target) => new() { Content = text, Target = target, Padding = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        Row(0, Caption("서비스(_S)", service), service);
        Row(1, new Label(), source);
        Row(2, Caption("키(_K)", key), new StackPanel { Children = { key, stored }, Margin = new Thickness(0, 8, 0, 0) });
        regionLabel.Target = region;
        regionLabel.VerticalAlignment = VerticalAlignment.Center;
        Row(3, regionLabel, new StackPanel { Children = { region }, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left });

        var note = new TextBlock
        {
            Text = "문서는 보내지 않습니다 — 확인은 그 서비스에 모델 목록만 묻습니다. 키는 Windows 자격 증명 관리자에 둡니다.",
            TextWrapping = TextWrapping.Wrap, MaxWidth = 460, Margin = new Thickness(0, 12, 0, 0), Opacity = 0.75,
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        void AddButton(string text, RoutedEventHandler click, bool isDefault = false, bool isCancel = false)
        {
            var button = new Button { Content = text, MinWidth = 80, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 3, 10, 3), IsDefault = isDefault, IsCancel = isCancel };
            button.Click += click;
            buttons.Children.Add(button);
        }
        AddButton("확인(_C)", async (_, _) => await CheckAsync(), isDefault: true);
        AddButton("저장(_A)", (_, _) => Save());
        AddButton("지우기(_D)", (_, _) => Remove());
        AddButton("닫기", (_, _) => Close(), isCancel: true);

        var stack = new StackPanel { Margin = new Thickness(16), MaxWidth = 520 };
        grid.Margin = new Thickness(0);
        stack.Children.Add(grid);
        stack.Children.Add(result);
        stack.Children.Add(note);
        stack.Children.Add(buttons);
        Content = stack;
        Refresh();
    }

    private LlmService Selected => (LlmService)((ComboBoxItem)service.SelectedItem).Tag;

    private static string Name(LlmService service) => $"llm/{service.ToString().ToLowerInvariant()}";

    private void Refresh()
    {
        var selected = Selected;
        source.Text = $"키 받는 곳: {selected.KeyConsole()} · 권장 모델: {selected.RecommendedModel()}";
        key.Clear();
        var has = Safe(() => CredentialStore.Read(Name(selected)) is { Length: > 0 });
        stored.Text = has ? "저장된 키가 있습니다(칸을 비워 두면 그것으로 확인합니다)" : "저장된 키가 없습니다";
        var needsRegion = selected.NeedsRegion();
        regionLabel.Visibility = region.Visibility = needsRegion ? Visibility.Visible : Visibility.Collapsed;
        region.Text = MainWindow.Store.HostText("bedrockRegion") ?? LlmServices.DefaultBedrockRegion;
        result.Text = "";
    }

    private string? CurrentKey() => key.Password.Length > 0 ? key.Password : Safe(() => CredentialStore.Read(Name(Selected)));

    private async Task CheckAsync()
    {
        var selected = Selected;
        var value = CurrentKey();
        if (string.IsNullOrWhiteSpace(value))
        {
            result.Text = "키를 넣습니다.";
            return;
        }
        result.Text = "확인하는 중…";
        IsEnabled = false;
        try
        {
            result.Text = await selected.CheckAsync(value, selected.NeedsRegion() ? region.Text.Trim() : null);
        }
        finally
        {
            IsEnabled = true;
        }
    }

    private void Save()
    {
        var selected = Selected;
        if (selected.NeedsRegion())
        {
            var name = region.Text.Trim();
            if (!LlmServices.IsValidRegion(name))
            {
                result.Text = "리전은 영문 소문자 · 숫자 · '-'만 씁니다(예: us-east-1).";
                return;
            }
            MainWindow.Store.SetHostText("bedrockRegion", name);
        }
        if (key.Password.Length > 0)
        {
            try
            {
                CredentialStore.Write(Name(selected), key.Password.Trim());
            }
            catch (Win32Exception error)
            {
                result.Text = $"저장하지 못했습니다: {error.Message}";
                return;
            }
        }
        Refresh();
        result.Text = "저장했습니다.";
    }

    private void Remove()
    {
        var removed = Safe(() => CredentialStore.Delete(Name(Selected)));
        Refresh();
        result.Text = removed ? "지웠습니다." : "저장된 키가 없었습니다.";
    }

    private static T? Safe<T>(Func<T> read)
    {
        try
        {
            return read();
        }
        catch (Win32Exception)
        {
            return default;
        }
    }
}
