package app.suiss.relay

import org.junit.Assert.assertEquals
import org.junit.Test

class RelayVersionTest {
    @Test
    fun `X-48 the SDK is pinned to one API version`() {
        assertEquals("2026-11-01", RelayVersion.API)
    }
}
