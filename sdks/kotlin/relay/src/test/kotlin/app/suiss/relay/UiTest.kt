package app.suiss.relay

import android.content.Context
import android.content.res.Configuration
import androidx.test.core.app.ApplicationProvider
import app.suiss.relay.ui.RelayPreferenceRowState
import app.suiss.relay.ui.RelayPreferencesModel
import app.suiss.relay.ui.RelayTurnOffChoice
import app.suiss.relay.ui.waitpointStatusText
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
import java.time.ZoneId
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

    @Test
    fun `PC-59 X-44 the preference centre reads the consents and never writes them`() =
        runBlocking<Unit> {
            val harness = Harness()
            val model =
                RelayPreferencesModel(RelayPreferencesApi(harness.http)) { RelayNotificationSettings(RelayPermission.GRANTED) }
            harness.server.enqueue("GET /v1/subscriber/preferences", Reply.json(200, preferences("{}")))
            val first = consent("cns_1", "email", "active", null) + "," + consent("cns_2", "sms", "pending_iys", "\"stn_1\"")
            harness.server.enqueue(
                "GET /v1/subscriber/consents",
                Reply.json(200, consents(first, true, "cns_2")),
                Reply.json(200, consents(consent("cns_3", "whatsapp", "revoked", null), false, null)),
            )
            model.load()
            val consents = model.consents.value
            assertEquals(listOf("cns_1", "cns_2", "cns_3"), consents.map { it.id })
            assertEquals(RelayConsentStatus.ACTIVE, consents[0].status)
            assertNull(consents[0].brand)
            assertEquals("explicit_opt_in", consents[0].consentKind)
            assertEquals(RelayConsentStatus.PENDING_IYS, consents[1].status)
            assertEquals("stn_1", consents[1].brand)
            assertEquals(RelayConsentStatus.REVOKED, consents[2].status)
            val requests = harness.server.requests("GET /v1/subscriber/consents")
            assertEquals(listOf("limit=100", "limit=100&starting_after=cns_2"), requests.map { it.query })
            assertTrue(harness.server.recorded.none { it.request.method != "GET" })
            assertEquals(4, model.preferences.value!!.cells.size)
        }

    @Test
    fun `X-44 unreadable consents leave the preferences shown`() =
        runBlocking<Unit> {
            val harness = Harness()
            val model =
                RelayPreferencesModel(RelayPreferencesApi(harness.http)) { RelayNotificationSettings(RelayPermission.GRANTED) }
            harness.server.enqueue("GET /v1/subscriber/preferences", Reply.json(200, preferences("{}")))
            harness.server.enqueue("GET /v1/subscriber/consents", Reply.problem(403, "auth_insufficient_scope", retryable = false))
            model.load()
            assertTrue(model.consents.value.isEmpty())
            assertEquals(4, model.preferences.value!!.cells.size)
            assertNull(model.lastError.value)
        }

    @Test
    fun `X-44 AG-35 consent and waitpoint texts in both languages`() {
        val english = localized(Locale.forLanguageTag("en-US"))
        val turkish = localized(Locale.forLanguageTag("tr-TR"))
        assertEquals("Marketing permissions", english.getString(R.string.relay_consents_title))
        assertEquals("Pazarlama izinleri", turkish.getString(R.string.relay_consents_title))
        assertEquals("İYS bekleniyor", turkish.getString(R.string.relay_consent_pending_iys))
        assertEquals("Email: Given", english.getString(R.string.relay_consent_status, "Email", "Given"))
        assertEquals("Sent by an AI agent", english.getString(R.string.relay_inbox_sender_agent))
        assertEquals("Bir yapay zekâ ajanı gönderdi", turkish.getString(R.string.relay_inbox_sender_agent))
        val utc = ZoneId.of("UTC")
        val en = Locale.forLanguageTag("en-US")
        val awaiting = RelayWaitpoint("wp_1", RelayWaitpointKind.RESPONSE, RelayWaitpointStatus.AWAITING, subjectDigest = Fixtures.DIGEST)
        assertEquals("Waiting for your response", waitpointStatusText(awaiting, english.resources, en, utc))
        assertEquals(
            "Yanıtınız işleniyor…",
            waitpointStatusText(awaiting.copy(status = RelayWaitpointStatus.PROCESSING), turkish.resources, en, utc),
        )
        assertEquals(
            "No longer expecting a response",
            waitpointStatusText(awaiting.copy(status = RelayWaitpointStatus.NOT_AWAITED), english.resources, en, utc),
        )
        val byAgent =
            awaiting.copy(
                status = RelayWaitpointStatus.RESPONDED,
                responder = RelayWaitpointResponder(isAgent = true, recipientId = "agt_1"),
                respondedAt = "2026-11-01T10:00:00Z",
            )
        val line = waitpointStatusText(byAgent, english.resources, en, utc)
        assertTrue(line.startsWith("Answered by an agent on "))
        assertTrue(line.contains("2026"))
        assertEquals(
            "Başka bir alıcı yanıtladı",
            waitpointStatusText(byAgent.copy(responder = null, respondedAt = null), turkish.resources, en, utc),
        )
        val bySubscriber = RelayWaitpointResponder(isAgent = false, recipientId = "sub_1")
        assertEquals(
            "Answered by you",
            waitpointStatusText(byAgent.copy(responder = bySubscriber, respondedAt = "not a time"), english.resources, en, utc),
        )
    }

    private fun consent(
        id: String,
        channel: String,
        status: String,
        brand: String?,
    ): String =
        """{"object":"consent","id":"$id","brand":${brand ?: "null"},"channel":"$channel","status":"$status",""" +
            """"consent_kind":"explicit_opt_in","recipient_type":"individual","source":"web","occurred_at":"2026-11-01T09:30:00Z"}"""

    private fun consents(
        data: String,
        more: Boolean,
        next: String?,
    ): String {
        val cursor = next?.let { "\"$it\"" } ?: "null"
        return """{"object":"list","data":[$data],"has_more":$more,"next_cursor":$cursor,"previous_cursor":null}"""
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
