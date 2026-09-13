defmodule PhoenixKitEntities.EventsTest do
  use ExUnit.Case

  alias PhoenixKitEntities.Events

  # Events module uses PubSub.Manager for subscribe/broadcast.
  # We test the topic construction and message shapes here.
  # Subscribe/broadcast integration is covered by the running PubSub in test_helper.

  describe "subscribe_to_entities/0" do
    test "subscribes without error" do
      assert :ok = Events.subscribe_to_entities()
    end
  end

  describe "subscribe_to_all_data/0" do
    test "subscribes without error" do
      assert :ok = Events.subscribe_to_all_data()
    end
  end

  describe "subscribe_to_entity_data/1" do
    test "subscribes to entity-specific data topic" do
      assert :ok = Events.subscribe_to_entity_data("some-uuid")
    end
  end

  describe "subscribe_to_entity_form/1" do
    test "subscribes to entity form topic" do
      assert :ok = Events.subscribe_to_entity_form("form-key")
    end
  end

  describe "subscribe_to_data_form/2" do
    test "subscribes to data form topic" do
      assert :ok = Events.subscribe_to_data_form("entity-uuid", "record-key")
    end
  end

  describe "subscribe_to_entity_presence/1" do
    test "subscribes to entity presence topic" do
      assert :ok = Events.subscribe_to_entity_presence("entity-uuid")
    end
  end

  describe "subscribe_to_data_presence/2" do
    test "subscribes to data presence topic" do
      assert :ok = Events.subscribe_to_data_presence("entity-uuid", "data-uuid")
    end
  end

  describe "entity definition broadcasts" do
    setup do
      Events.subscribe_to_entities()
      :ok
    end

    test "broadcast_entity_created/1 sends {:entity_created, uuid}" do
      Events.broadcast_entity_created("uuid-123")
      assert_receive {:entity_created, "uuid-123"}
    end

    test "broadcast_entity_updated/1 sends {:entity_updated, uuid}" do
      Events.broadcast_entity_updated("uuid-123")
      assert_receive {:entity_updated, "uuid-123"}
    end

    test "broadcast_entity_deleted/1 sends {:entity_deleted, uuid}" do
      Events.broadcast_entity_deleted("uuid-123")
      assert_receive {:entity_deleted, "uuid-123"}
    end
  end

  describe "entity data broadcasts" do
    setup do
      Events.subscribe_to_all_data()
      Events.subscribe_to_entity_data("entity-1")
      :ok
    end

    test "broadcast_data_created/2 sends to both global and entity topics" do
      Events.broadcast_data_created("entity-1", "data-1")
      # Receive from global topic
      assert_receive {:data_created, "entity-1", "data-1"}
      # Receive from entity-specific topic
      assert_receive {:data_created, "entity-1", "data-1"}
    end

    test "broadcast_data_updated/2 sends to both topics" do
      Events.broadcast_data_updated("entity-1", "data-1")
      assert_receive {:data_updated, "entity-1", "data-1"}
      assert_receive {:data_updated, "entity-1", "data-1"}
    end

    test "broadcast_data_deleted/2 sends to both topics" do
      Events.broadcast_data_deleted("entity-1", "data-1")
      assert_receive {:data_deleted, "entity-1", "data-1"}
      assert_receive {:data_deleted, "entity-1", "data-1"}
    end

    test "broadcast_data_reordered/1 sends to both topics" do
      Events.broadcast_data_reordered("entity-1")
      assert_receive {:data_reordered, "entity-1"}
      assert_receive {:data_reordered, "entity-1"}
    end
  end

  describe "flush_data_events/0" do
    test "drops queued data lifecycle messages and keeps everything else" do
      send(self(), {:data_deleted, "entity-1", "data-1"})
      send(self(), {:data_updated, "entity-1", "data-2"})
      send(self(), {:data_reordered, "entity-1"})
      send(self(), {:data_created, "entity-1", "data-3"})

      assert :ok = Events.flush_data_events()

      assert_received {:data_reordered, "entity-1"}
      refute_received {:data_deleted, _, _}
      refute_received {:data_updated, _, _}
      refute_received {:data_created, _, _}
    end

    test "returns immediately on an empty mailbox" do
      assert :ok = Events.flush_data_events()
    end
  end

  describe "entity form collaborative broadcasts" do
    setup do
      Events.subscribe_to_entity_form("form-abc")
      :ok
    end

    test "broadcast_entity_form_change/3 sends form change event" do
      Events.broadcast_entity_form_change("form-abc", %{field: "name"}, source: "socket-1")
      assert_receive {:entity_form_change, "form-abc", %{field: "name"}, "socket-1"}
    end

    test "broadcast_entity_form_change/2 with no opts sends nil source" do
      Events.broadcast_entity_form_change("form-abc", %{field: "name"})
      assert_receive {:entity_form_change, "form-abc", %{field: "name"}, nil}
    end

    test "broadcast_entity_form_sync_request/2 sends sync request" do
      Events.broadcast_entity_form_sync_request("form-abc", "requester-1")
      assert_receive {:entity_form_sync_request, "form-abc", "requester-1"}
    end

    test "broadcast_entity_form_sync_response/3 sends sync response" do
      Events.broadcast_entity_form_sync_response("form-abc", "requester-1", %{data: "state"})
      assert_receive {:entity_form_sync_response, "form-abc", "requester-1", %{data: "state"}}
    end
  end

  describe "data form collaborative broadcasts" do
    setup do
      Events.subscribe_to_data_form("entity-1", "record-1")
      :ok
    end

    test "broadcast_data_form_change/4 sends form change event" do
      Events.broadcast_data_form_change("entity-1", "record-1", %{field: "title"}, source: "s1")
      assert_receive {:data_form_change, "entity-1", "record-1", %{field: "title"}, "s1"}
    end

    test "broadcast_data_form_sync_request/3 sends sync request" do
      Events.broadcast_data_form_sync_request("entity-1", "record-1", "requester-1")
      assert_receive {:data_form_sync_request, "entity-1", "record-1", "requester-1"}
    end

    test "broadcast_data_form_sync_response/4 sends sync response" do
      Events.broadcast_data_form_sync_response("entity-1", "record-1", "req-1", %{state: 1})
      assert_receive {:data_form_sync_response, "entity-1", "record-1", "req-1", %{state: 1}}
    end
  end

  describe "record key normalization" do
    setup do
      Events.subscribe_to_data_form("entity-1", "new-contact")
      :ok
    end

    test "tuple {:new, slug} is normalized to string" do
      Events.broadcast_data_form_change("entity-1", {:new, "contact"}, %{}, [])
      assert_receive {:data_form_change, "entity-1", "new-contact", %{}, nil}
    end

    test "atom key is normalized to string" do
      Events.subscribe_to_data_form("entity-1", "draft")
      Events.broadcast_data_form_change("entity-1", :draft, %{}, [])
      assert_receive {:data_form_change, "entity-1", "draft", %{}, nil}
    end
  end
end
