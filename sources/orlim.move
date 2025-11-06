/*
/// Module: orlim
module orlim::orlim;
*/

// For Move coding conventions, see
// https://docs.sui.io/concepts/sui-move-concepts/conventions

module orlim::orlim {
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::option;
    use sui::table::{Self, Table};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    // Error codes
    const EORDER_NOT_FOUND: u64 = 2;
    const EINVALID_PRICE: u64 = 4;
    const EINVALID_QUANTITY: u64 = 5;
    const EUNAUTHORIZED: u64 = 6;
    const ECONTRACT_PAUSED: u64 = 7;
    const ETIMESTAMP_INVALID: u64 = 8;
    const EORDER_ALREADY_CANCELLED: u64 = 9;

    // Events
    public struct OrderPlacedEvent has copy, drop {
        order_id: u64,
        pool_id: vector<u8>,
        user: address,
        price: u64,
        quantity: u64,
        is_bid: bool,
        created_at: u64,
    }

    public struct OrderCancelledEvent has copy, drop {
        order_id: u64,
        user: address,
        cancelled_at: u64,
    }

    public struct OrderModifiedEvent has copy, drop {
        order_id: u64,
        old_price: u64,
        new_price: u64,
        old_quantity: u64,
        new_quantity: u64,
        modified_at: u64,
    }

    public struct ContractPausedEvent has copy, drop {
        paused: bool,
        paused_at: u64,
        admin: address,
    }

    // Optimized OrderReceipt data structure (no UID for gas efficiency)
    public struct OrderReceiptData has store, copy, drop {
        order_id: u64,
        pool_id: vector<u8>,
        price: u64,
        quantity: u64,
        is_bid: bool,
        created_at: u64,
        is_active: bool,
        cancelled_at: option::Option<u64>,
    }

    public struct OrderManager has key, store {
        id: UID,
        owner: address,
        active_orders: vector<u64>,
        total_orders_created: u64,
        receipts: Table<u64, OrderReceiptData>,
        is_paused: bool,
        created_at: u64,
    }

    public struct AdminCap has key, store {
        id: UID,
    }

    /// Initialize the module with admin capabilities
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::public_transfer(admin_cap, tx_context::sender(ctx));
    }

    /// Create a new order manager for the user
    public fun create_order_manager(clock: &Clock, ctx: &mut TxContext) {
        let manager = OrderManager {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            active_orders: vector::empty<u64>(),
            total_orders_created: 0,
            receipts: table::new(ctx),
            is_paused: false,
            created_at: clock::timestamp_ms(clock),
        };
        transfer::public_transfer(manager, tx_context::sender(ctx));
    }

    /// Place a limit order with security checks and optimized storage
    public fun place_limit_order(
        manager: &mut OrderManager,
        pool_id: vector<u8>,
        price: u64,
        quantity: u64,
        is_bid: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        // Security and validation checks
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(!manager.is_paused, ECONTRACT_PAUSED);
        assert!(price > 0, EINVALID_PRICE);
        assert!(quantity > 0, EINVALID_QUANTITY);

        let created_at = clock::timestamp_ms(clock);
        assert!(created_at > manager.created_at, ETIMESTAMP_INVALID);

        let order_id = created_at + manager.total_orders_created;

        // Record order in manager
        vector::push_back(&mut manager.active_orders, order_id);
        manager.total_orders_created = manager.total_orders_created + 1;

        // Store receipt data in Table (gas efficient)
        let receipt_data = OrderReceiptData {
            order_id,
            pool_id,
            price,
            quantity,
            is_bid,
            created_at,
            is_active: true,
            cancelled_at: option::none(),
        };
        table::add(&mut manager.receipts, order_id, receipt_data);

        // Emit event
        event::emit(OrderPlacedEvent {
            order_id,
            pool_id,
            user: manager.owner,
            price,
            quantity,
            is_bid,
            created_at,
        });

        order_id
    }

    /// Cancel a limit order with security checks
    public fun cancel_limit_order(
        manager: &mut OrderManager,
        order_id: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Security checks
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(!manager.is_paused, ECONTRACT_PAUSED);

        // Verify order exists and is active
        assert!(vector::contains(&manager.active_orders, &order_id), EORDER_NOT_FOUND);

        let receipt_data = table::borrow_mut(&mut manager.receipts, order_id);
        assert!(receipt_data.is_active, EORDER_ALREADY_CANCELLED);

        let cancelled_at = clock::timestamp_ms(clock);
        assert!(cancelled_at > receipt_data.created_at, ETIMESTAMP_INVALID);

        // Update receipt data
        receipt_data.is_active = false;
        receipt_data.cancelled_at = option::some(cancelled_at);

        // Remove from active orders
        let mut i = 0;
        let len = vector::length(&manager.active_orders);
        while (i < len) {
            if (*vector::borrow(&manager.active_orders, i) == order_id) {
                vector::remove(&mut manager.active_orders, i);
                break
            };
            i = i + 1;
        };

        // Emit event
        event::emit(OrderCancelledEvent {
            order_id,
            user: manager.owner,
            cancelled_at,
        });
    }

    /// Get user's active orders
    public fun get_user_orders(manager: &OrderManager): &vector<u64> {
        &manager.active_orders
    }

    /// Get total orders created by user
    public fun get_total_orders_created(manager: &OrderManager): u64 {
        manager.total_orders_created
    }

    /// Check if order is active
    public fun is_order_active(manager: &OrderManager, order_id: u64): bool {
        vector::contains(&manager.active_orders, &order_id)
    }

    /// Get receipt details from Table (gas efficient)
    public fun get_receipt_details(manager: &OrderManager, order_id: u64): &OrderReceiptData {
        table::borrow(&manager.receipts, order_id)
    }

    /// Get order manager owner
    public fun get_manager_owner(manager: &OrderManager): address {
        manager.owner
    }

    /// Check if contract is paused
    public fun is_contract_paused(manager: &OrderManager): bool {
        manager.is_paused
    }

    /// Modify an existing order (price or quantity)
    public fun modify_order(
        manager: &mut OrderManager,
        order_id: u64,
        new_price: option::Option<u64>,
        new_quantity: option::Option<u64>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Security checks
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(!manager.is_paused, ECONTRACT_PAUSED);
        assert!(vector::contains(&manager.active_orders, &order_id), EORDER_NOT_FOUND);

        let receipt_data = table::borrow_mut(&mut manager.receipts, order_id);
        assert!(receipt_data.is_active, EORDER_ALREADY_CANCELLED);

        let modified_at = clock::timestamp_ms(clock);
        assert!(modified_at > receipt_data.created_at, ETIMESTAMP_INVALID);

        let old_price = receipt_data.price;
        let old_quantity = receipt_data.quantity;

        // Update price if provided
        if (option::is_some(&new_price)) {
            let price = option::destroy_some(new_price);
            assert!(price > 0, EINVALID_PRICE);
            receipt_data.price = price;
        };

        // Update quantity if provided
        if (option::is_some(&new_quantity)) {
            let quantity = option::destroy_some(new_quantity);
            assert!(quantity > 0, EINVALID_QUANTITY);
            receipt_data.quantity = quantity;
        };

        // Store final values for event
        let final_price = receipt_data.price;
        let final_quantity = receipt_data.quantity;

        // Emit modification event
        event::emit(OrderModifiedEvent {
            order_id,
            old_price,
            new_price: final_price,
            old_quantity,
            new_quantity: final_quantity,
            modified_at,
        });
    }

    /// Emergency pause/unpause contract (admin only)
    public fun toggle_pause(
        _admin_cap: &AdminCap,
        manager: &mut OrderManager,
        paused: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        manager.is_paused = paused;
        event::emit(ContractPausedEvent {
            paused,
            paused_at: clock::timestamp_ms(clock),
            admin: tx_context::sender(ctx),
        });
    }

    /// Transfer OrderManager ownership
    public fun transfer_manager(
        manager: OrderManager,
        recipient: address,
        _ctx: &mut TxContext,
    ) {
        transfer::public_transfer(manager, recipient);
    }

    /// Cancel multiple orders with error handling (atomic operation fix)
    public fun cancel_multiple_orders_safe(
        manager: &mut OrderManager,
        mut order_ids: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(!manager.is_paused, ECONTRACT_PAUSED);

        let len = vector::length(&order_ids);
        let mut i = 0;
        let mut successful_cancellations = vector::empty<u64>();

        while (i < len) {
            let order_id = *vector::borrow(&order_ids, i);

            // Try to cancel each order, continue even if one fails
            if (vector::contains(&manager.active_orders, &order_id)) {
                let receipt_data = table::borrow(&manager.receipts, order_id);
                if (receipt_data.is_active) {
                    // Cancel this order
                    cancel_limit_order(manager, order_id, clock, ctx);
                    vector::push_back(&mut successful_cancellations, order_id);
                }
            };
            i = i + 1;
        };

        // Clean up
        while (vector::length(&order_ids) > 0) {
            vector::pop_back(&mut order_ids);
        };
        vector::destroy_empty(order_ids);
        while (vector::length(&successful_cancellations) > 0) {
            vector::pop_back(&mut successful_cancellations);
        };
        vector::destroy_empty(successful_cancellations);
    }

    /// Update order status (for when DeepBook fills/cancels orders)
    public fun update_order_status(
        manager: &mut OrderManager,
        order_id: u64,
        is_active: bool,
    ) {
        if (table::contains(&manager.receipts, order_id)) {
            let receipt_data = table::borrow_mut(&mut manager.receipts, order_id);
            receipt_data.is_active = is_active;

            if (!is_active && receipt_data.is_active) {
                // Remove from active orders if deactivating
                let mut i = 0;
                let len = vector::length(&manager.active_orders);
                while (i < len) {
                    if (*vector::borrow(&manager.active_orders, i) == order_id) {
                        vector::remove(&mut manager.active_orders, i);
                        break
                    };
                    i = i + 1;
                };
            };
        }
    }

    // === Entry Functions ===

    /// Entry function to create order manager
    public entry fun create_order_manager_entry(clock: &Clock, ctx: &mut TxContext) {
        create_order_manager(clock, ctx);
    }

    /// Entry function to place limit order
    public entry fun place_limit_order_entry(
        manager: &mut OrderManager,
        pool_id: vector<u8>,
        price: u64,
        quantity: u64,
        is_bid: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        place_limit_order(
            manager,
            pool_id,
            price,
            quantity,
            is_bid,
            clock,
            ctx,
        );
    }

    /// Entry function to cancel limit order
    public entry fun cancel_limit_order_entry(
        manager: &mut OrderManager,
        order_id: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        cancel_limit_order(
            manager,
            order_id,
            clock,
            ctx,
        );
    }

    /// Entry function to cancel multiple orders in batch (with error handling)
    public entry fun cancel_multiple_orders_entry(
        manager: &mut OrderManager,
        order_ids: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        cancel_multiple_orders_safe(
            manager,
            order_ids,
            clock,
            ctx,
        );
    }

    /// Entry function to modify an order
    public entry fun modify_order_entry(
        manager: &mut OrderManager,
        order_id: u64,
        new_price: u64,
        new_quantity: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Basic validation in entry function for faster failure
        assert!(new_price > 0, EINVALID_PRICE);
        assert!(new_quantity > 0, EINVALID_QUANTITY);

        modify_order(
            manager,
            order_id,
            option::some(new_price),
            option::some(new_quantity),
            clock,
            ctx,
        );
    }

    /// Entry function to transfer manager ownership
    public entry fun transfer_manager_entry(
        manager: OrderManager,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == get_manager_owner(&manager), EUNAUTHORIZED);
        transfer_manager(manager, recipient, ctx);
    }
}


