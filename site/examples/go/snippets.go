package docsexamples

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"

	relay "github.com/e-suiss/relay/sdks/go"
)

func Quickstart(ctx context.Context) error {
	// #region quickstart
	auth, err := relay.NewClientCredentials("https://access.example.com",
		os.Getenv("ACCESS_CLIENT_ID"), os.Getenv("ACCESS_CLIENT_SECRET"),
		relay.WithScope("publish read"))
	if err != nil {
		return err
	}
	client, err := relay.NewClient("https://relay.example.com", auth)
	if err != nil {
		return err
	}

	accepted, err := client.CreateEvent(ctx, &relay.EventRequest{
		Workflow: "welcome",
		To:       []relay.RecipientTarget{map[string]any{"id": "user-4821", "email": "ayse@example.com"}},
		Data:     map[string]any{"first_name": "Ayşe"},
	}, nil)
	if err != nil {
		return err
	}
	fmt.Println(string(accepted))
	// #endregion quickstart

	// #region decisions
	for decision, err := range client.ListSubscriberDecisionsIter(ctx, "user-4821", nil) {
		if err != nil {
			return err
		}
		for _, delivery := range decision.Deliveries {
			fmt.Println(decision.NotificationID, delivery.Channel, delivery.Status, delivery.Gates)
		}
	}
	// #endregion decisions

	// #region errors
	_, err = client.CreateEvent(ctx, &relay.EventRequest{Workflow: "welcome"}, nil,
		relay.WithIdempotencyKey("order:4821:shipped"))
	var invalid *relay.ValidationError
	if errors.As(err, &invalid) {
		fmt.Println(invalid.Code, invalid.Detail, invalid.RequestID)
	}
	// #endregion errors
	return nil
}

var processed sync.Map

// #region verify
func WebhookHandler() (http.Handler, error) {
	verifier, err := relay.NewWebhookVerifier(os.Getenv("RELAY_WEBHOOK_KEY"))
	if err != nil {
		return nil, err
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if _, err := verifier.Verify(body, r.Header); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if _, seen := processed.LoadOrStore(r.Header.Get("webhook-id"), true); !seen {
			fmt.Println("received", r.Header.Get("webhook-event-type"))
		}
		w.WriteHeader(http.StatusNoContent)
	}), nil
}

// #endregion verify
