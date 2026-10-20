package org.shaolinmobiu;

import android.content.SharedPreferences;
import android.content.Intent;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import org.libsdl.app.SDLActivity;

import java.io.IOException;
import java.io.File;
import java.io.FileWriter;
import java.util.ArrayList;

/**
 * Keeps the user-granted game file descriptor alive while the native SDL activity runs.
 * The original ISO/XBE is not copied and does not require broad storage permission.
 */
public final class ShaolinActivity extends SDLActivity {
    private static final String TAG = "ShaolinMobiu";
    private ParcelFileDescriptor gameDescriptor;

    @Override
    protected String[] getLibraries() {
        return new String[] {"SDL3", "main"};
    }

    @Override
    protected String[] getArguments() {
        SharedPreferences prefs = getSharedPreferences(LauncherActivity.PREFERENCES, MODE_PRIVATE);
        Intent launch = getIntent();
        int fps = launch.getIntExtra(LauncherActivity.KEY_FPS,
            prefs.getInt(LauncherActivity.KEY_FPS, 60));
        int scale = launch.getIntExtra(LauncherActivity.KEY_RESOLUTION,
            prefs.getInt(LauncherActivity.KEY_RESOLUTION, 75));
        ArrayList<String> args = new ArrayList<>();
        args.add("--fps");
        args.add(Integer.toString(fps == 30 ? 30 : 60));
        args.add("--scale");
        args.add(Integer.toString(scale));
        // App-private trace survives logcat restrictions and is readable via
        // adb shell run-as in debug APKs; never contains ROM bytes or game paths.
        File trace = new File(getFilesDir(), "shaolin-native-trace.txt");
        try (FileWriter writer = new FileWriter(trace, false)) {
            writer.write("JAVA_ACTIVITY_GET_ARGUMENTS\n");
        } catch (IOException e) {
            Log.e(TAG, "Cannot create private startup trace", e);
        }
        args.add("--trace-file");
        args.add(trace.getAbsolutePath());
        String renderer = setting(launch, prefs, LauncherActivity.KEY_RENDERER, "vulkan");
        args.add("--renderer");
        args.add("opengl".equals(renderer) ? "opengl" : "vulkan");
        Log.i(TAG, "Launching genuine Xbox game graphics backend: " + renderer);

        final String uriText = setting(launch, prefs, LauncherActivity.KEY_GAME_URI, "");
        final String kind = setting(launch, prefs, LauncherActivity.KEY_GAME_KIND, "");
        if ("file".equals(kind) && !uriText.isEmpty()) {
            try {
                // The SDL thread and the native main entry share the same Linux process.
                // Native code can read this fd with pread; Java owns and closes it.
                if (gameDescriptor == null) {
                    gameDescriptor = getContentResolver().openFileDescriptor(Uri.parse(uriText), "r");
                }
                if (gameDescriptor != null) {
                    args.add("--game-fd");
                    args.add(Integer.toString(gameDescriptor.getFd()));
                    Log.i(TAG, "Read-only Xbox game source opened for native GameBoot");
                }
            } catch (SecurityException | IOException | IllegalArgumentException e) {
                Log.e(TAG, "Cannot open saved game document permission: " + e.getClass().getSimpleName());
            }
        }
        return args.toArray(new String[0]);
    }

    private static String setting(Intent intent, SharedPreferences prefs, String key, String fallback) {
        String value = intent.hasExtra(key) ? intent.getStringExtra(key) : prefs.getString(key, fallback);
        return value == null ? fallback : value;
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (gameDescriptor != null) {
            try {
                gameDescriptor.close();
            } catch (IOException e) {
                Log.w(TAG, "Failed to close game descriptor", e);
            }
            gameDescriptor = null;
        }
    }
}
