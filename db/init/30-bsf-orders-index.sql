-- WHERE customer_email = ? ORDER BY created_at DESC.
ALTER TABLE wp_bsf_orders
  ADD INDEX customer_email_created (customer_email, created_at);
