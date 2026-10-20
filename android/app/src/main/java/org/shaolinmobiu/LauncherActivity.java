package org.shaolinmobiu;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.Locale;

/**
 * Standalone Android launcher for the ARM64 bringup.
 * The game document URI and preferences are stored privately and are never uploaded.
 * Private GameBoot builds can start the genuine recompiled Xbox guest thread.
 * Graphics/audio compatibility must still be verified on a device.
 */
public final class LauncherActivity extends Activity {
    public static final String PREFERENCES = "shaolin_launcher";
    public static final String KEY_GAME_URI = "game_uri";
    public static final String KEY_GAME_NAME = "game_name";
    public static final String KEY_GAME_KIND = "game_kind";
    public static final String KEY_RESOLUTION = "render_percent";
    public static final String KEY_FPS = "fps_cap";

    private static final int REQUEST_GAME = 1201;
    private static final int REQUEST_FOLDER = 1202;
    private static final int BG = Color.rgb(12, 11, 17);
    private static final int PANEL = Color.rgb(24, 22, 30);
    private static final int ACCENT = Color.rgb(242, 72, 65);
    private static final int GOLD = Color.rgb(245, 179, 91);
    private static final int WHITE = Color.rgb(247, 241, 233);
    private static final int MUTED = Color.rgb(167, 162, 169);
    private static final int BORDER = Color.rgb(52, 43, 53);

    private SharedPreferences prefs;
    private LinearLayout root;
    private TextView gameDetails;
    private String verificationStatus = "";
    private boolean nativeGameBootBuild;
    private LinearLayout resOptions;
    private LinearLayout fpsOptions;

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private GradientDrawable background(int top, int bottom, int radius) {
        GradientDrawable drawable = new GradientDrawable(
            GradientDrawable.Orientation.TL_BR, new int[]{top, bottom});
        drawable.setCornerRadius(dp(radius));
        return drawable;
    }

    private GradientDrawable outlined(int fill, int stroke, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(dp(radius));
        drawable.setStroke(dp(1), stroke);
        return drawable;
    }

    private LinearLayout vertical() {
        LinearLayout linear = new LinearLayout(this);
        linear.setOrientation(LinearLayout.VERTICAL);
        return linear;
    }

    private TextView text(String title, int size, int color, boolean bold) {
        TextView view = new TextView(this);
        view.setText(title);
        view.setTextColor(color);
        view.setTextSize(size);
        view.setIncludeFontPadding(false);
        if (bold) view.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        else view.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        return view;
    }

    private LinearLayout.LayoutParams verticalParams(int marginTop, int marginBottom) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.setMargins(0, dp(marginTop), 0, dp(marginBottom));
        return params;
    }

    private Button button(String label, boolean primary, Runnable action) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(15);
        b.setTextColor(primary ? Color.WHITE : WHITE);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setGravity(Gravity.CENTER);
        b.setMinHeight(dp(56));
        b.setBackground(primary
            ? background(Color.rgb(218, 51, 57), Color.rgb(137, 29, 49), 16)
            : outlined(Color.rgb(34, 30, 39), BORDER, 16));
        b.setOnClickListener(view -> action.run());
        return b;
    }

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        prefs = getSharedPreferences(PREFERENCES, MODE_PRIVATE);
        try {
            String version = getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
            nativeGameBootBuild = version != null && version.contains("xbox-gameboot");
        } catch (android.content.pm.PackageManager.NameNotFoundException ignored) {
            nativeGameBootBuild = false;
        }
        buildLayout();
    }

    private void buildLayout() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(BG);
        scroll.setVerticalScrollBarEnabled(false);
        root = vertical();
        root.setPadding(dp(20), dp(24), dp(20), dp(36));
        scroll.addView(root);
        setContentView(scroll);

        LinearLayout header = new LinearLayout(this);
        header.setGravity(Gravity.CENTER_VERTICAL);
        TextView mark = text("✦", 27, GOLD, true);
        mark.setGravity(Gravity.CENTER);
        mark.setBackground(background(Color.rgb(91, 33, 39), Color.rgb(42, 25, 35), 14));
        header.addView(mark, new LinearLayout.LayoutParams(dp(48), dp(48)));
        LinearLayout identity = vertical();
        identity.setPadding(dp(12), 0, 0, 0);
        identity.addView(text("SHAOLIN MOBIU", 16, WHITE, true));
        TextView sub = text("ANDROID • ARM64 • VULKAN", 10, MUTED, true);
        sub.setLetterSpacing(0.11f);
        identity.addView(sub, verticalParams(4, 0));
        header.addView(identity, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView about = text("ⓘ", 25, MUTED, false);
        about.setGravity(Gravity.CENTER);
        about.setContentDescription("Sobre esta versão");
        about.setOnClickListener(v -> showAbout());
        header.addView(about, new LinearLayout.LayoutParams(dp(42), dp(48)));
        root.addView(header);

        LinearLayout hero = vertical();
        hero.setPadding(dp(22), dp(23), dp(22), dp(25));
        hero.setBackground(background(Color.rgb(95, 27, 41), Color.rgb(22, 19, 29), 26));
        root.addView(hero, verticalParams(25, 0));

        TextView badge = text(nativeGameBootBuild
            ? "●  XBOX GAMEBOOT ARM64" : "●  PRÉVIA DE DESENVOLVIMENTO", 11, GOLD, true);
        badge.setLetterSpacing(0.1f);
        hero.addView(badge);
        TextView title = text("SHAOLIN", 41, WHITE, true);
        title.setLetterSpacing(-0.055f);
        hero.addView(title, verticalParams(18, 0));
        TextView second = text("MONKS", 49, WHITE, true);
        second.setLetterSpacing(-0.055f);
        hero.addView(second);
        View accentLine = new View(this);
        accentLine.setBackground(background(ACCENT, GOLD, 4));
        LinearLayout.LayoutParams accentParams = new LinearLayout.LayoutParams(dp(72), dp(4));
        accentParams.setMargins(0, dp(12), 0, dp(16));
        hero.addView(accentLine, accentParams);
        TextView description = text(nativeGameBootBuild
            ? "Carregue sua ISO original para iniciar o kernel Xbox e a thread do jogo. "
                + "O renderizador D3D8 e o áudio ainda podem impedir a imagem ou causar crashes."
            : "Este APK público é apenas uma prévia de gráficos. Use a compilação "
                + "GameBoot privada para executar o código Xbox recompilado.",
            14, Color.rgb(221, 205, 203), false);
        description.setLineSpacing(dp(4), 1f);
        hero.addView(description);

        TextView section = text("BIBLIOTECA", 12, GOLD, true);
        section.setLetterSpacing(0.15f);
        root.addView(section, verticalParams(28, 13));
        LinearLayout game = vertical();
        game.setPadding(dp(17), dp(17), dp(17), dp(17));
        game.setBackground(outlined(PANEL, BORDER, 20));
        game.addView(text("Mortal Kombat: Shaolin Monks", 18, WHITE, true));
        gameDetails = text("", 13, MUTED, false);
        gameDetails.setLineSpacing(dp(3), 1f);
        game.addView(gameDetails, verticalParams(9, 14));
        game.addView(button("Selecionar ISO / XISO / ZIP / XBE", true, this::chooseGame),
            verticalParams(0, 0));
        game.addView(button("Selecionar pasta extraída", false, this::chooseFolder),
            verticalParams(9, 0));
        game.addView(button("Verificar arquivo selecionado", false, this::inspectSelectedGame),
            verticalParams(9, 0));
        root.addView(game);
        refreshGameDetails();

        section = text("MODS KRYPT", 12, GOLD, true);
        section.setLetterSpacing(0.15f);
        root.addView(section, verticalParams(28, 13));
        LinearLayout mods = vertical();
        mods.setPadding(dp(17), dp(18), dp(17), dp(18));
        mods.setBackground(outlined(PANEL, BORDER, 20));
        mods.addView(text("Mods e traduções", 18, WHITE, true));
        mods.addView(text("Instale pacotes Krypt .tar.xz, gerencie atualizações, " +
            "dependências e habilitações. Aplicação dentro do jogo ainda em desenvolvimento.",
            12, MUTED, false), verticalParams(9, 12));
        mods.addView(button("Gerenciar mods Krypt", true, () ->
            startActivity(new Intent(this, ModManagerActivity.class))));
        root.addView(mods);

        section = text("CONFIGURAÇÕES", 12, GOLD, true);
        section.setLetterSpacing(0.15f);
        root.addView(section, verticalParams(28, 13));
        LinearLayout settings = vertical();
        settings.setBackground(outlined(PANEL, BORDER, 20));
        settings.setPadding(dp(17), dp(19), dp(17), dp(19));
        settings.addView(text("Escala de resolução", 16, WHITE, true));
        settings.addView(text("Preferência salva para o port do jogo", 12, MUTED, false),
            verticalParams(5, 11));
        resOptions = new LinearLayout(this);
        settings.addView(resOptions);
        settings.addView(text("Limite de FPS", 16, WHITE, true), verticalParams(20, 0));
        settings.addView(text("Aplicado ao teste Vulkan", 12, MUTED, false),
            verticalParams(5, 11));
        fpsOptions = new LinearLayout(this);
        settings.addView(fpsOptions);
        root.addView(settings);
        refreshOptions();

        section = text("INICIAR", 12, GOLD, true);
        section.setLetterSpacing(0.15f);
        root.addView(section, verticalParams(28, 13));
        if (nativeGameBootBuild) {
            root.addView(button("▶  JOGAR SHAOLIN MONKS", true, this::startGameBoot));
        } else {
            root.addView(button("▶  TESTAR GRÁFICOS VULKAN", true, this::startNative));
            root.addView(button("Jogar Shaolin Monks  •  Requer GameBoot", false,
                this::showNotPlayable), verticalParams(11, 0));
        }

        TextView footer = text(nativeGameBootBuild
            ? "XBOX GAMEBOOT  •  ISO original necessária.\n"
                + "A execução pode falhar enquanto os serviços gráficos são integrados."
            : "PRÉVIA TÉCNICA  •  Nenhum arquivo do jogo está incluso.\n"
                + "O teste Vulkan não executa a campanha.",
            11, MUTED, false);
        footer.setGravity(Gravity.CENTER);
        footer.setLineSpacing(dp(4), 1f);
        root.addView(footer, verticalParams(26, 0));
    }

    private void renderChoices(LinearLayout row, int[] values, int current,
                               String suffix, java.util.function.IntConsumer choice) {
        row.removeAllViews();
        for (int index = 0; index < values.length; index++) {
            final int v = values[index];
            TextView chip = text(v + suffix, 14, current == v ? WHITE : MUTED, true);
            chip.setGravity(Gravity.CENTER);
            chip.setMinHeight(dp(46));
            chip.setBackground(current == v
                ? outlined(Color.rgb(110, 37, 49), ACCENT, 13)
                : outlined(Color.rgb(29, 27, 34), BORDER, 13));
            LinearLayout.LayoutParams params =
                new LinearLayout.LayoutParams(0, dp(46), 1f);
            if (index > 0) params.leftMargin = dp(8);
            row.addView(chip, params);
            chip.setOnClickListener(view -> choice.accept(v));
        }
    }

    private void refreshOptions() {
        int scale = prefs.getInt(KEY_RESOLUTION, 75);
        int fps = prefs.getInt(KEY_FPS, 60);
        renderChoices(resOptions, new int[]{50, 75, 100}, scale, "%", value -> {
            prefs.edit().putInt(KEY_RESOLUTION, value).apply();
            refreshOptions();
        });
        renderChoices(fpsOptions, new int[]{30, 60}, fps, " FPS", value -> {
            prefs.edit().putInt(KEY_FPS, value).apply();
            refreshOptions();
        });
    }

    private void chooseGame() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION |
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        try {
            startActivityForResult(intent, REQUEST_GAME);
        } catch (ActivityNotFoundException e) {
            new AlertDialog.Builder(this).setMessage("Não foi encontrado um seletor de arquivos.")
                .setPositiveButton("OK", null).show();
        }
    }

    private void chooseFolder() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION |
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        try {
            startActivityForResult(intent, REQUEST_FOLDER);
        } catch (ActivityNotFoundException e) {
            new AlertDialog.Builder(this).setMessage("Não foi encontrado um seletor de pastas.")
                .setPositiveButton("OK", null).show();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if ((requestCode != REQUEST_GAME && requestCode != REQUEST_FOLDER)
            || resultCode != RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData();
        try {
            final int permissionFlags = data.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION;
            getContentResolver().takePersistableUriPermission(uri, permissionFlags);
        } catch (SecurityException e) {
            Toast.makeText(this, "Não foi possível manter o acesso ao arquivo.", Toast.LENGTH_LONG).show();
            return;
        }
        String name;
        String type;
        if (requestCode == REQUEST_FOLDER) {
            String id = DocumentsContract.getTreeDocumentId(uri);
            name = id == null ? "Pasta selecionada" : id.substring(id.lastIndexOf('/') + 1);
            type = "folder";
        } else {
            name = getDocumentName(uri);
            String lower = name.toLowerCase(Locale.ROOT);
            if (!(lower.endsWith(".iso") || lower.endsWith(".xiso") || lower.endsWith(".zip") ||
                  lower.endsWith(".xbe"))) {
                new AlertDialog.Builder(this)
                    .setTitle("Formato não reconhecido")
                    .setMessage("Selecione ISO, XISO, ZIP ou default.xbe de sua cópia original.")
                    .setPositiveButton("OK", null).show();
                return;
            }
            type = "file";
        }
        prefs.edit().putString(KEY_GAME_URI, uri.toString())
            .putString(KEY_GAME_NAME, name).putString(KEY_GAME_KIND, type).apply();
        verificationStatus = "";
        refreshGameDetails();
        inspectSelectedGame();
    }

    private String getDocumentName(Uri uri) {
        try (Cursor cursor = getContentResolver().query(uri,
            new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) return cursor.getString(0);
        } catch (RuntimeException ignored) {
        }
        return uri.getLastPathSegment() == null ? "Arquivo do jogo" : uri.getLastPathSegment();
    }

    private void refreshGameDetails() {
        String uri = prefs.getString(KEY_GAME_URI, "");
        if (uri.isEmpty()) {
            gameDetails.setText("Nenhum jogo selecionado. Selecione sua cópia original do Xbox.");
            return;
        }
        String kind = prefs.getString(KEY_GAME_KIND, "file").equals("folder") ? "Pasta" : "Arquivo";
        gameDetails.setText("✓  " + kind + " selecionado: " +
            prefs.getString(KEY_GAME_NAME, "Jogo") +
            "\n" + (verificationStatus.isEmpty()
                ? "Acesso salvo no Android. Toque em Verificar arquivo para analisar."
                : verificationStatus) +
            (nativeGameBootBuild
                ? "\nPronto para tentar iniciar o Xbox GameBoot pela ISO."
                : "\nEste APK não contém o código Xbox recompilado."));
    }

    private void inspectSelectedGame() {
        String document = prefs.getString(KEY_GAME_URI, "");
        if (document.isEmpty()) {
            Toast.makeText(this, "Selecione primeiro o arquivo original do Xbox.", Toast.LENGTH_SHORT).show();
            return;
        }
        verificationStatus = "Verificando a fonte selecionada em segundo plano…";
        refreshGameDetails();
        GameSourceInspector.inspect(this, Uri.parse(document),
            prefs.getString(KEY_GAME_NAME, ""), prefs.getString(KEY_GAME_KIND, "file"),
            result -> {
                if (!document.equals(prefs.getString(KEY_GAME_URI, ""))) return;
                verificationStatus = result;
                refreshGameDetails();
            });
    }

    private void startNative() {
        Intent intent = new Intent(this, ShaolinActivity.class);
        startActivity(intent);
    }

    private void startGameBoot() {
        if (!nativeGameBootBuild) {
            showNotPlayable();
            return;
        }
        final String uri = prefs.getString(KEY_GAME_URI, "");
        final String kind = prefs.getString(KEY_GAME_KIND, "");
        final String name = prefs.getString(KEY_GAME_NAME, "").toLowerCase(Locale.ROOT);
        if (uri.isEmpty() || !"file".equals(kind) ||
            !(name.endsWith(".iso") || name.endsWith(".xiso"))) {
            new AlertDialog.Builder(this)
                .setTitle("Selecione a ISO do Shaolin Monks")
                .setMessage("Para iniciar a CPU Xbox, selecione a ISO/XISO completa e original na Biblioteca. Arquivos ZIP e pastas não são suportados pelo GameBoot.")
                .setNegativeButton("Cancelar", null)
                .setPositiveButton("Selecionar ISO", (dialog, which) -> chooseGame())
                .show();
            return;
        }
        startNative();
    }

    private void showNotPlayable() {
        new AlertDialog.Builder(this)
            .setTitle("Versão GameBoot necessária")
            .setMessage("Este APK é o launcher público sem código de jogo recompilado. " +
                "Instale sua compilação privada ShaolinMobiu-ARM64-GameBoot.apk para iniciar o kernel Xbox usando sua ISO.")
            .setPositiveButton("Entendi", null).show();
    }

    private void showAbout() {
        new AlertDialog.Builder(this)
            .setTitle("SHAOLIN MOBIU")
            .setMessage(nativeGameBootBuild
                ? "GameBoot ARM64: inicia o kernel Xbox e tenta rodar o XBE original da ISO.\n\n" +
                    "A imagem D3D8 do jogo e áudio ainda estão em integração.\n" +
                    "Nenhum arquivo licenciado está incluído."
                : "Prévia pública do launcher ARM64 e Vulkan.\n\n" +
                    "Não contém o código do jogo. Compile a versão privada GameBoot para executar sua ISO.")
            .setPositiveButton("Fechar", null).show();
    }
}
