package app.suiss.relay

import android.content.Context
import android.content.res.Configuration
import androidx.test.core.app.ApplicationProvider
import app.suiss.relay.ui.RelayPreferenceRowState
import app.suiss.relay.ui.RelayPreferencesModel
import app.suiss.relay.ui.RelayTurnOffChoice
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.Locale

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class UiTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun `X-32 Turkish and English texts cover the same keys`() {
        val res = File("src/main/res")
        val english = keys(res.resolve("values/strings.xml"))
        val turkish = keys(res.resolve("values-tr/strings.xml"))
        assertTrue(english.isNotEmpty())
        assertEquals(english, turkish)
        assertEquals("Açık (kilitli)", localized(Locale.forLanguageTag("tr-TR")).getString(R.string.relay_prefs_locked_on))
        assertEquals("On (locked)", localized(Locale.forLanguageTag("en-US")).getString(R.string.relay_prefs_locked_on))
        assertEquals("Bildirimler, 3 yeni", localized(Locale.forLanguageTag("tr-TR")).getString(R.string.relay_bell_label, 3))
        assertEquals("Never", localized(Locale.forLanguageTag("de-DE")).getString(R.string.relay_prefs_never))
    }

    @Test
    fun `PC-15 PC-16 X-51 row states`() {
        fun cell(
            channel: String,
            source: RelayPreferenceSource,
            effective: Boolean,
            locked: Boolean = false,
            admin: Boolean = false,
            device: Boolean = false,
        ) =
            RelayPreferenceCell(
                category = "orders",
                channel = channel,
                value = RelayPreferenceValue.UNSET,
                effective = effective,
                source = source,
                locked = locked,
                lockBeneficiary = RelayLockBeneficiary.SUBSCRIBER.takeIf { locked },
                disabledByAdmin = admin,
                disabledInDeviceSettings = device,
            )
        assertEquals(
            RelayPreferenceRowState.LOCKED_ON,
            RelayPreferenceRowState.of(cell("email", RelayPreferenceSource.LOCKED, true, locked = true), RelayPermission.GRANTED),
        )
        assertEquals(
            RelayPreferenceRowState.ADMIN_DISABLED,
            RelayPreferenceRowState.of(cell("email", RelayPreferenceSource.TENANT, false, admin = true), RelayPermission.GRANTED),
        )
        assertEquals(
            RelayPreferenceRowState.OFF,
            RelayPreferenceRowState.of(cell("email", RelayPreferenceSource.TENANT, false), RelayPermission.GRANTED),
        )
        assertEquals(
            RelayPreferenceRowState.DEVICE_DISABLED,
            RelayPreferenceRowState.of(cell("push", RelayPreferenceSource.USER, true), RelayPermission.DENIED),
        )
        assertEquals(
            RelayPreferenceRowState.DEVICE_DISABLED,
            RelayPreferenceRowState.of(cell("web_push", RelayPreferenceSource.USER, true, device = true), RelayPermission.GRANTED),
        )
        assertEquals(
            RelayPreferenceRowState.PERMISSION_PENDING,
            RelayPreferenceRowState.of(cell("push", RelayPreferenceSource.CLASS_DEFAULT, true), RelayPermission.NOT_DETERMINED),
        )
        assertEquals(
            RelayPreferenceRowState.OFF,
            RelayPreferenceRowState.of(cell("sms", RelayPreferenceSource.USER, false), RelayPermission.DENIED),
        )
        assertTrue(RelayPreferenceRowState.ON.isEditable)
        assertFalse(RelayPreferenceRowState.LOCKED_ON.isEditable)
    }

    @Test
    fun `PC-17 turning a digest category off asks three choices first`() =
        runBlocking<Unit> {
            val harness = Harness()
            val model =
                RelayPreferencesModel(RelayPreferencesApi(harness.http)) { RelayNotificationSettings(RelayPermission.GRANTED) }
            harness.server.enqueue("GET /v1/subscriber/preferences", Reply.json(200, preferences("{}")))
            model.load()
            val cell = model.preferences.value!!.cells.first()
            assertTrue(cell.digestAllowed)
            assertEquals("Friends", model.name("friends"))
            model.set(cell, false)
            assertEquals(cell, model.pendingTurnOff.value)
            assertTrue(harness.server.requests("PATCH /v1/subscriber/preferences").isEmpty())
            harness.server.enqueue("PATCH /v1/subscriber/preferences", Reply.json(200, preferences("{\"friends\":\"digest\"}")))
            model.choose(RelayTurnOffChoice.DIGEST)
            val body = harness.server.requests("PATCH /v1/subscriber/preferences").single().json
            assertEquals("digest", body.getAsJsonObject("profile").getAsJsonObject("digest").get("friends").asString)
            assertNull(body.get("preferences"))
            assertEquals(RelayDigestChoice.DIGEST, model.preferences.value!!.digest["friends"])
        }

    @Test
    fun `X-31 a preference write sends only the cell`() =
        runBlocking<Unit> {
            val harness = Harness()
            harness.server.enqueue("PATCH /v1/subscriber/preferences", Reply.json(200, preferences("{}")))
            RelayPreferencesApi(harness.http).set("friends", "email", RelayPreferenceValue.OPT_OUT)
            val body = harness.server.requests("PATCH /v1/subscriber/preferences").single().json
            assertNull(body.get("profile"))
            val write = body.getAsJsonArray("preferences").single().asJsonObject
            assertEquals("category_channel", write.get("level").asString)
            assertEquals("opt_out", write.get("value").asString)
        }

    @Test
    fun `X-51 a cell carries its lock, administrator and device states`() =
        runBlocking<Unit> {
            val harness = Harness()
            val model =
                RelayPreferencesModel(RelayPreferencesApi(harness.http)) { RelayNotificationSettings(RelayPermission.GRANTED) }
            harness.server.enqueue("GET /v1/subscriber/preferences", Reply.json(200, preferences("{}")))
            model.load()
            val cells = model.preferences.value!!.cells
            assertEquals(4, cells.size)
            assertEquals("Sign-in alerts", cells[1].categoryName)
            assertTrue(cells[1].locked)
            assertEquals(RelayLockBeneficiary.SUBSCRIBER, cells[1].lockBeneficiary)
            assertEquals(RelayPreferenceRowState.LOCKED_ON, model.state(cells[1]))
            assertTrue(cells[2].disabledByAdmin)
            assertEquals(RelayPreferenceRowState.ADMIN_DISABLED, model.state(cells[2]))
            assertTrue(cells[3].disabledInDeviceSettings)
            assertEquals(RelayPreferenceRowState.DEVICE_DISABLED, model.state(cells[3]))
            assertNull(cells[0].lockBeneficiary)
            assertEquals(RelayPreferenceRowState.ON, model.state(cells[0]))
            assertEquals(
                "Locked: protects your account",
                localized(Locale.forLanguageTag("en-US")).getString(R.string.relay_prefs_locked_subscriber),
            )
            assertEquals(
                "Kilitli: hizmet için gerekli",
                localized(Locale.forLanguageTag("tr-TR")).getString(R.string.relay_prefs_locked_tenant),
            )
        }

    private fun localized(locale: Locale): Context {
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(locale)
        return context.createConfigurationContext(configuration)
    }

    private fun keys(file: File): Set<String> =
        Regex("<string name=\"([a-z_]+)\"").findAll(file.readText()).map {
            it.groupValues[1]
        }.toSet()

    private fun preferences(digest: String): String =
        """{"object":"subscriber_preferences","subscriber_id":"sub_01j9zq3k4m5n6p7q8r9s0t1v2w",""" +
            """"cells":[""" +
            """{"category":"friends","category_name":"Friends","channel":"email","value":"unset","effective":true,""" +
            """"source":"class_default","locked":false,"lock_beneficiary":null,"disabled_by_admin":false,""" +
            """"disabled_in_device_settings":false,"digest_allowed":true},""" +
            """{"category":"sign_in","category_name":"Sign-in alerts","channel":"email","value":"unset","effective":true,""" +
            """"source":"locked","locked":true,"lock_beneficiary":"subscriber","disabled_by_admin":false,""" +
            """"disabled_in_device_settings":false,"digest_allowed":false},""" +
            """{"category":"offers","category_name":"Offers","channel":"sms","value":"opt_out","effective":false,""" +
            """"source":"tenant","locked":false,"lock_beneficiary":null,"disabled_by_admin":true,""" +
            """"disabled_in_device_settings":false,"digest_allowed":false},""" +
            """{"category":"friends","category_name":"Friends","channel":"web_push","value":"unset","effective":true,""" +
            """"source":"class_default","locked":false,"lock_beneficiary":null,"disabled_by_admin":false,""" +
            """"disabled_in_device_settings":true,"digest_allowed":true}],""" +
            """"channels":[],"workflows":[],"scope_keys":[],"profile":{"quiet_hours":[],"schedule":[],"dnd_until":null,""" +
            """"quiet_hours_email":false,"digest":$digest}}"""
}
