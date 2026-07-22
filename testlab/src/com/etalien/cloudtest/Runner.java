package com.etalien.cloudtest;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import android.view.accessibility.AccessibilityNodeInfo;

import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class Runner extends Instrumentation {
    private static final String TAG = "ETAlienCloudTest";
    private static final String PACKAGE = "com.etalien.booster";
    private static final String PREFIX = PACKAGE + ":id/";
    private static final Pattern PROGRESS = Pattern.compile("(\\d+)\\s*/\\s*(\\d+)");

    private Bundle arguments;
    private UiAutomation automation;

    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        this.arguments = arguments;
        start();
    }

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        try {
            automation = getUiAutomation();
            String token = requiredArgument("ETALIEN_TOKEN");
            String dvc = arguments.getString("ETALIEN_DVC", "");
            injectSession(token, dvc);
            openPcRewardPage();

            int before = readProgress();
            result.putInt("progress_before", before);
            Log.i(TAG, "PC reward progress before ad: " + before + "/9");

            clickById("UIADSubmit", 20_000);
            boolean adOpened = waitForAdToOpen(50_000);
            result.putBoolean("ad_opened", adOpened);
            if (!adOpened) {
                throw new IllegalStateException("Rewarded ad stayed in loading state");
            }

            waitForAdAndReturn(90_000);
            int after = readProgress();
            result.putInt("progress_after", after);
            Log.i(TAG, "PC reward progress after ad: " + after + "/9");
            if (after <= before) {
                throw new IllegalStateException("Reward callback did not advance PC progress");
            }
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            Log.e(TAG, "Physical-device probe failed: " + error.getMessage(), error);
            result.putString("error", error.toString());
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private String requiredArgument(String name) {
        String value = arguments.getString(name, "");
        if (value.isEmpty()) {
            throw new IllegalArgumentException(name + " is required");
        }
        return value;
    }

    private void injectSession(String token, String dvc) throws Exception {
        Context target = getTargetContext();
        SharedPreferences.Editor editor = target
            .getSharedPreferences("spUtils", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("AGREE_PRIVACY", true)
            .putString("CUR_USER_TOKEN", token);
        if (!dvc.isEmpty()) {
            editor.putString("CACHE_ANDROID_ID", dvc);
        }
        if (!editor.commit()) {
            throw new IllegalStateException("Session preference injection failed");
        }
        shell("am start -W -n " + PACKAGE + "/com.etalien.booster.ui.SplashActivity");
        Log.i(TAG, "Session injected into debuggable Test Lab fixture");
    }

    private void openPcRewardPage() throws Exception {
        sleep(3_000);
        for (int attempt = 0; attempt < 3; attempt++) {
            AccessibilityNodeInfo confirmation = findById("UISubmit");
            if (confirmation == null) break;
            click(confirmation);
            sleep(3_000);
        }
        clickById("UISwitch", 20_000);
        waitForAnyId("UIPCDurationCard", 20_000);
        waitForAnyId("UIADSubmit", 20_000);
        Log.i(TAG, "PC reward page opened");
    }

    private boolean waitForAdToOpen(long timeoutMs) throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (findById("UIPCDurationCard") == null) {
                Log.i(TAG, "Rewarded ad activity became visible");
                return true;
            }
            sleep(1_000);
        }
        return false;
    }

    private void waitForAdAndReturn(long timeoutMs) throws Exception {
        long closeAfter = System.currentTimeMillis() + 75_000;
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (findById("UIPCDurationCard") != null) {
                return;
            }
            if (System.currentTimeMillis() >= closeAfter) {
                clickFirstText("\u9886\u53d6\u5956\u52b1", "\u5173\u95ed", "\u5b8c\u6210");
            }
            sleep(2_000);
        }
        shell("input keyevent KEYCODE_BACK");
        waitForAnyId("UIPCDurationCard", 15_000);
    }

    private int readProgress() throws Exception {
        AccessibilityNodeInfo root = waitForRoot(15_000);
        List<AccessibilityNodeInfo> nodes = root.findAccessibilityNodeInfosByViewId(PREFIX + "UIStateTitle");
        for (AccessibilityNodeInfo node : nodes) {
            CharSequence text = node.getText();
            if (text == null) continue;
            Matcher matcher = PROGRESS.matcher(text);
            if (matcher.find()) return Integer.parseInt(matcher.group(1));
        }
        throw new IllegalStateException("PC progress node was not found");
    }

    private void clickFirstText(String... labels) {
        AccessibilityNodeInfo root = automation.getRootInActiveWindow();
        if (root == null) return;
        for (String label : labels) {
            List<AccessibilityNodeInfo> nodes = root.findAccessibilityNodeInfosByText(label);
            if (!nodes.isEmpty()) {
                click(nodes.get(0));
                return;
            }
        }
    }

    private void clickById(String id, long timeoutMs) throws Exception {
        AccessibilityNodeInfo node = waitForAnyId(id, timeoutMs);
        if (!click(node)) throw new IllegalStateException("Could not click " + id);
    }

    private boolean click(AccessibilityNodeInfo node) {
        AccessibilityNodeInfo current = node;
        while (current != null) {
            if (current.isClickable()) return current.performAction(AccessibilityNodeInfo.ACTION_CLICK);
            current = current.getParent();
        }
        return false;
    }

    private AccessibilityNodeInfo waitForAnyId(String id, long timeoutMs) throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            AccessibilityNodeInfo node = findById(id);
            if (node != null) return node;
            sleep(500);
        }
        throw new IllegalStateException("Timed out waiting for " + id);
    }

    private AccessibilityNodeInfo findById(String id) {
        AccessibilityNodeInfo root = automation.getRootInActiveWindow();
        if (root == null) return null;
        List<AccessibilityNodeInfo> nodes = root.findAccessibilityNodeInfosByViewId(PREFIX + id);
        return nodes.isEmpty() ? null : nodes.get(0);
    }

    private AccessibilityNodeInfo waitForRoot(long timeoutMs) throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            AccessibilityNodeInfo root = automation.getRootInActiveWindow();
            if (root != null) return root;
            sleep(500);
        }
        throw new IllegalStateException("Timed out waiting for an accessibility root");
    }

    private String shell(String command) throws Exception {
        ParcelFileDescriptor descriptor = automation.executeShellCommand(command);
        StringBuilder output = new StringBuilder();
        try (FileInputStream input = new ParcelFileDescriptor.AutoCloseInputStream(descriptor)) {
            byte[] buffer = new byte[4096];
            int length;
            while ((length = input.read(buffer)) != -1) {
                output.append(new String(buffer, 0, length, StandardCharsets.UTF_8));
            }
        }
        return output.toString();
    }

    private static void sleep(long milliseconds) throws InterruptedException {
        Thread.sleep(milliseconds);
    }
}
