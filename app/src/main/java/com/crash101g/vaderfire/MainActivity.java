package com.crash101g.vaderfire;

import android.app.Activity;
import android.content.res.AssetFileDescriptor;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.FrameLayout;

import java.io.IOException;

public class MainActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "VaderFireplace";
    private static final String KEY_POSITION = "position";

    private SurfaceView surfaceView;
    private MediaPlayer player;
    private boolean surfaceReady;
    private boolean resumed;
    private int savedPosition;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (savedInstanceState != null) {
            savedPosition = savedInstanceState.getInt(KEY_POSITION, 0);
        }

        Window window = getWindow();
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        surfaceView = new SurfaceView(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        setContentView(root);

        surfaceView.getHolder().addCallback(this);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemUi();
    }

    @SuppressWarnings("deprecation")
    private void hideSystemUi() {
        Window window = getWindow();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false);
            WindowInsetsController c = window.getInsetsController();
            if (c != null) {
                c.hide(WindowInsets.Type.systemBars());
                c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            window.getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                            | View.SYSTEM_UI_FLAG_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        hideSystemUi();
        startIfReady();
    }

    @Override
    protected void onPause() {
        resumed = false;
        releasePlayer();
        super.onPause();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putInt(KEY_POSITION, player != null ? player.getCurrentPosition() : savedPosition);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        surfaceReady = true;
        startIfReady();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        releasePlayer();
    }

    private void startIfReady() {
        if (!resumed || !surfaceReady || player != null) return;

        MediaPlayer mp = new MediaPlayer();
        try (AssetFileDescriptor afd = getResources().openRawResourceFd(R.raw.vader_fire)) {
            mp.setDataSource(afd.getFileDescriptor(), afd.getStartOffset(), afd.getLength());
        } catch (IOException e) {
            Log.e(TAG, "Unable to open video", e);
            mp.release();
            return;
        }
        mp.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build());
        mp.setDisplay(surfaceView.getHolder());
        mp.setScreenOnWhilePlaying(true);
        mp.setLooping(true);
        mp.setOnPreparedListener(p -> {
            if (savedPosition > 0) p.seekTo(savedPosition);
            p.start();
        });
        mp.setOnErrorListener((p, what, extra) -> {
            Log.e(TAG, "MediaPlayer error " + what + "/" + extra);
            return false;
        });
        player = mp;
        mp.prepareAsync();
    }

    private void releasePlayer() {
        if (player == null) return;
        try {
            savedPosition = player.getCurrentPosition();
        } catch (IllegalStateException ignored) {
        }
        player.release();
        player = null;
    }
}
