package com.etalien.cloudtest;

import android.test.InstrumentationTestCase;

public final class ProbeTest extends InstrumentationTestCase {
    public void testPhysicalProbe() throws Throwable {
        ((Runner) getInstrumentation()).runProbe();
    }
}
