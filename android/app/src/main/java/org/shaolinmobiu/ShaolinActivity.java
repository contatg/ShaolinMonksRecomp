package org.shaolinmobiu;

import android.content.SharedPreferences;
import org.libsdl.app.SDLActivity;

public final class ShaolinActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] {"SDL3", "main"};
    }

    @Override
    protected String[] getArguments() {
        SharedPreferences prefs = getSharedPreferences(LauncherActivity.PREFERENCES, MODE_PRIVATE);
        int fps = prefs.getInt(LauncherActivity.KEY_FPS, 60);
        int scale = prefs.getInt(LauncherActivity.KEY_RESOLUTION, 75);
        return new String[] {
            "--fps", Integer.toString(fps == 30 ? 30 : 60),
            "--scale", Integer.toString(scale)
        };
    }
}
