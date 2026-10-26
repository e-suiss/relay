
  SELECT now() + CASE WHEN relay_private.ctx_environment() = 'test'
    THEN coalesce((SELECT offset_ms FROM relay.virtual_clocks
                   WHERE tenant_id = relay_private.ctx_tenant_id() AND environment = 'test'), 0)
         * interval '1 millisecond'
    ELSE interval '0' END
