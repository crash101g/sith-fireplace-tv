package com.crash101g.sithfire;

import android.content.res.AssetFileDescriptor;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.service.dreams.DreamService;
import android.util.Log;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.FrameLayout;

import java.io.IOException;

/**
 * Screensaver ("Daydream") that plays the same seamless fireplace loop as
 * {@link MainActivity}. Any remote button press wakes the TV back up.
 */
public class SithDreamService extends DreamService implements SurfaceHolder.Callback {
    private static final String TAG = "SithFireplaceDream";

    /** Screensavers start on their own, so the crackle is off by default. */
    private static final boolean PLAY_AUDIO = false;

    private SurfaceView surfaceView;
    private MediaPlayer player;
    private boolean surfaceReady;
    private boolean dreaming;

    @Override
    public void onAttachedToWindow() {
        super.onAttachedToWindow();
        setInteractive(false);   // any key ends the dream
        setFullscreen(true);
        setScreenBright(true);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        surfaceView = new SurfaceView(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        setContentView(root);
        surfaceView.getHolder().addCallback(this);
    }

    @Override
    public void onDreamingStarted() {
        super.onDreamingStarted();
        dreaming = true;
        startIfReady();
    }

    @Override
    public void onDreamingStopped() {
        dreaming = false;
        releasePlayer();
        super.onDreamingStopped();
    }

    @Override
    public void onDetachedFromWindow() {
        releasePlayer();
        super.onDetachedFromWindow();
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
        if (!dreaming || !surfaceReady || player != null) return;

        MediaPlayer mp = new MediaPlayer();
        try (AssetFileDescriptor afd = getResources().openRawResourceFd(R.raw.sith_fire)) {
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
        if (!PLAY_AUDIO) mp.setVolume(0f, 0f);
        mp.setDisplay(surfaceView.getHolder());
        mp.setLooping(true);
        mp.setOnPreparedListener(MediaPlayer::start);
        mp.setOnErrorListener((p, what, extra) -> {
            Log.e(TAG, "MediaPlayer error " + what + "/" + extra);
            return false;
        });
        player = mp;
        mp.prepareAsync();
    }

    private void releasePlayer() {
        if (player == null) return;
        player.release();
        player = null;
    }
}
