package org.shaolinmobiu;

import org.libsdl.app.SDLActivity;

public class ShaolinActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] {"SDL3", "main"};
    }
}
