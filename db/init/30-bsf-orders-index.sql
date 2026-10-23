-- Lookup is WHERE customer_email = ? ORDER BY created_at DESC LIMIT 10.
-- The seed is ~2M rows and the table previously only had the primary key.
ALTER TABLE wp_bsf_orders
  ADD INDEX customer_email_created (customer_email, created_at);
