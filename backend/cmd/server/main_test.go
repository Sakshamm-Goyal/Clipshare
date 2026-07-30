package main

import "testing"

func TestValidateJWTSecret(t *testing.T) {
	for _, secret := range []string{"", "short", "CHANGE_ME_IN_PRODUCTION"} {
		if err := validateJWTSecret(secret); err == nil {
			t.Fatalf("expected %q to be rejected", secret)
		}
	}
	if err := validateJWTSecret("32-byte-test-secret-for-clipshare!"); err != nil {
		t.Fatalf("expected valid secret: %v", err)
	}
}
