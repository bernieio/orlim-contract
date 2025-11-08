/*
/// Module: orlim
module orlim::orlim;
*/

// For Move coding conventions, see
// https://docs.sui.io/concepts/sui-move-concepts/conventions

module orlim::orlim {
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;
    use std::option;
    use sui::table::{Self, Table};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID};
    // DeepBook imports will be added when implementing real DeepBook integration

    // Error codes (sequential numbering)
    const EORDER_NOT_FOUND: u64 = 0;
    const EINVALID_PRICE: u64 = 1;
    const EINVALID_QUANTITY: u64 = 2;
    const EUNAUTHORIZED: u64 = 3;
    const ECONTRACT_PAUSED: u64 = 4;
    const ETIMESTAMP_INVALID: u64 = 5;
    const EORDER_ALREADY_CANCELLED: u64 = 6;
    const EOCO_GROUP_NOT_FOUND: u64 = 7;
    const EORDER_ALREADY_FILLED: u64 = 8;
    const EINVALID_TIF_TYPE: u64 = 9;
    const EORDER_EXPIRED: u64 = 10;
    const EOCO_ORDER_FILLED: u64 = 11;

    // Order Type Enums
    public struct OrderType has copy, drop, store {
        value: u8,
    }

    public struct TimeInForce has copy, drop, store {
        value: u8,
    }

    // OrderType constants
    const STANDARD: u8 = 0;
    const OCO: u8 = 1;
    const TIF: u8 = 2;

    // TimeInForce constants
    const GTC: u8 = 0; // Good Till Canceled
    const IOC: u8 = 1; // Immediate or Cancel
    const FOK: u8 = 2; // Fill or Kill

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

    // OCO-specific events
    public struct OCOOrderPlacedEvent has copy, drop {
        oco_group_id: u64,
        order_id_1: u64,
        order_id_2: u64,
        user: address,
        created_at: u64,
    }

    public struct OCOOrderFilledEvent has copy, drop {
        oco_group_id: u64,
        filled_order_id: u64,
        cancelled_order_id: u64,
        user: address,
        filled_at: u64,
    }

    public struct OCOOrderCancelledEvent has copy, drop {
        oco_group_id: u64,
        cancelled_order_id: u64,
        user: address,
        cancelled_at: u64,
    }

    // TIF-specific events
    public struct TIFOrderPlacedEvent has copy, drop {
        order_id: u64,
        tif_type: u8,
        user: address,
        created_at: u64,
    }

    public struct OrderPartialFilledEvent has copy, drop {
        order_id: u64,
        filled_quantity: u64,
        remaining_quantity: u64,
        user: address,
        filled_at: u64,
    }

    public struct OrderExpiredEvent has copy, drop {
        order_id: u64,
        user: address,
        expired_at: u64,
    }

    // Order Ownership events
    public struct OrderOwnershipTransferredEvent has copy, drop {
        order_id: u64,
        from: address,
        to: address,
        transferred_at: u64,
    }

    public struct OrderCancelledByOwnerEvent has copy, drop {
        order_id: u64,
        owner: address,
        cancelled_at: u64,
    }

    // Enhanced OrderReceiptData with OCO and TIF support
    public struct OrderReceiptData has store, copy, drop {
        order_id: u64,
        deepbook_order_id: u64, // Real DeepBook order ID for cancellation
        pool_id: vector<u8>,
        price: u64,
        quantity: u64,
        original_quantity: u64,
        is_bid: bool,
        order_type: OrderType,
        time_in_force: TimeInForce,
        created_at: u64,
        is_active: bool,
        is_fully_filled: bool,
        cancelled_at: option::Option<u64>,
        oco_group_id: option::Option<u64>, // Using u64 for performance with timestamp + counter
        expires_at: option::Option<u64>,
    }

    // OCO Group for linked order management
    public struct OCOGroup has key, store {
        id: UID,
        group_id: u64,
        order1_id: u64,
        order2_id: u64,
        created_at: u64,
        is_active: bool,
    }

    // Owned OrderReceipt for transferability
    public struct OrderReceipt has key, store {
        id: UID,
        order_data: OrderReceiptData,
        owner: address,
    }

    public struct OrderManager has key, store {
        id: UID,
        owner: address,
        active_orders: vector<u64>,
        total_orders_created: u64,
        receipts: Table<u64, OrderReceiptData>,
        oco_groups: Table<u64, OCOGroup>,
        is_paused: bool,
        created_at: u64,
        // DeepBook integration components
        deepbook_pools: Table<vector<u8>, UID>, // pool_id -> Pool UID
        // account_cap: AccountCap, // Will be added when implementing real DeepBook integration
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

    /// Create a new order manager for the user (DeepBook integration pending)
    public fun create_order_manager(clock: &Clock, ctx: &mut TxContext) {
        let manager = OrderManager {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            active_orders: vector::empty<u64>(),
            total_orders_created: 0,
            receipts: table::new(ctx),
            oco_groups: table::new(ctx),
            is_paused: false,
            created_at: clock::timestamp_ms(clock),
            deepbook_pools: table::new(ctx),
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
            deepbook_order_id: order_id, // Mock - in real implementation would get from DeepBook
            pool_id,
            price,
            quantity,
            original_quantity: quantity,
            is_bid,
            order_type: OrderType { value: STANDARD },
            time_in_force: TimeInForce { value: GTC },
            created_at,
            is_active: true,
            is_fully_filled: false,
            cancelled_at: option::none(),
            oco_group_id: option::none(),
            expires_at: option::none(),
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

    /// Place OCO (One-Cancels-Other) limit order pair
    public fun place_limit_order_oco(
        manager: &mut OrderManager,
        pool_id: vector<u8>,
        order1_price: u64,
        order1_quantity: u64,
        order1_is_bid: bool,
        order2_price: u64,
        order2_quantity: u64,
        order2_is_bid: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, u64) {
        // Security and validation checks
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(!manager.is_paused, ECONTRACT_PAUSED);
        assert!(order1_price > 0 && order2_price > 0, EINVALID_PRICE);
        assert!(order1_quantity > 0 && order2_quantity > 0, EINVALID_QUANTITY);

        let created_at = clock::timestamp_ms(clock);
        assert!(created_at > manager.created_at, ETIMESTAMP_INVALID);

        // Generate OCO group ID
        let oco_group_id = created_at + manager.total_orders_created;

        // Generate order IDs
        let order1_id = oco_group_id;
        let order2_id = oco_group_id + 1000000; // Offset to ensure uniqueness

        // Add orders to active orders
        vector::push_back(&mut manager.active_orders, order1_id);
        vector::push_back(&mut manager.active_orders, order2_id);
        manager.total_orders_created = manager.total_orders_created + 2;

        // Create OCO group
        let oco_group = OCOGroup {
            id: object::new(ctx),
            group_id: oco_group_id,
            order1_id,
            order2_id,
            created_at,
            is_active: true,
        };
        table::add(&mut manager.oco_groups, oco_group_id, oco_group);

        // Create receipt data for order 1
        let receipt_data_1 = OrderReceiptData {
            order_id: order1_id,
            deepbook_order_id: order1_id, // Mock - in real implementation would get from DeepBook
            pool_id: pool_id,
            price: order1_price,
            quantity: order1_quantity,
            original_quantity: order1_quantity,
            is_bid: order1_is_bid,
            order_type: OrderType { value: OCO },
            time_in_force: TimeInForce { value: GTC },
            created_at,
            is_active: true,
            is_fully_filled: false,
            cancelled_at: option::none(),
            oco_group_id: option::some(oco_group_id),
            expires_at: option::none(),
        };
        table::add(&mut manager.receipts, order1_id, receipt_data_1);

        // Create receipt data for order 2
        let receipt_data_2 = OrderReceiptData {
            order_id: order2_id,
            deepbook_order_id: order2_id, // Mock - in real implementation would get from DeepBook
            pool_id: vector::empty<u8>(), // Use empty vector for second order
            price: order2_price,
            quantity: order2_quantity,
            original_quantity: order2_quantity,
            is_bid: order2_is_bid,
            order_type: OrderType { value: OCO },
            time_in_force: TimeInForce { value: GTC },
            created_at,
            is_active: true,
            is_fully_filled: false,
            cancelled_at: option::none(),
            oco_group_id: option::some(oco_group_id),
            expires_at: option::none(),
        };
        table::add(&mut manager.receipts, order2_id, receipt_data_2);

        // Emit OCO-specific event
        event::emit(OCOOrderPlacedEvent {
            oco_group_id,
            order_id_1: order1_id,
            order_id_2: order2_id,
            user: manager.owner,
            created_at,
        });

        // Also emit individual order events
        event::emit(OrderPlacedEvent {
            order_id: order1_id,
            pool_id: vector::empty(), // Will be populated by DeepBook integration
            user: manager.owner,
            price: order1_price,
            quantity: order1_quantity,
            is_bid: order1_is_bid,
            created_at,
        });

        event::emit(OrderPlacedEvent {
            order_id: order2_id,
            pool_id: vector::empty(), // Will be populated by DeepBook integration
            user: manager.owner,
            price: order2_price,
            quantity: order2_quantity,
            is_bid: order2_is_bid,
            created_at,
        });

        (order1_id, order2_id)
    }

    /// Handle OCO order fill (cancel the linked order)
    public fun handle_oco_fill(
        manager: &mut OrderManager,
        filled_order_id: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(table::contains(&manager.receipts, filled_order_id), EORDER_NOT_FOUND);

        let filled_receipt = table::borrow(&manager.receipts, filled_order_id);
        assert!(filled_receipt.is_active, EORDER_ALREADY_FILLED);

        if (option::is_some(&filled_receipt.oco_group_id)) {
            let oco_group_id = *option::borrow(&filled_receipt.oco_group_id);
            assert!(table::contains(&manager.oco_groups, oco_group_id), EOCO_GROUP_NOT_FOUND);

            // Get linked order ID and update OCO group
            let (linked_order_id, oco_group_exists) = {
                let mut oco_group = table::remove(&mut manager.oco_groups, oco_group_id);
                let linked_id = if (oco_group.order1_id == filled_order_id) {
                    oco_group.order2_id
                } else {
                    oco_group.order1_id
                };
                oco_group.is_active = false;
                table::add(&mut manager.oco_groups, oco_group_id, oco_group);
                (linked_id, true)
            };

            let cancelled_at = clock::timestamp_ms(clock);

            // Cancel linked order if it exists
            if (table::contains(&manager.receipts, linked_order_id)) {
                let mut linked_receipt = table::remove(&mut manager.receipts, linked_order_id);
                if (linked_receipt.is_active) {
                    linked_receipt.is_active = false;
                    linked_receipt.cancelled_at = option::some(cancelled_at);

                    // Remove from active orders
                    let mut i = 0;
                    let len = vector::length(&manager.active_orders);
                    while (i < len) {
                        if (*vector::borrow(&manager.active_orders, i) == linked_order_id) {
                            vector::remove(&mut manager.active_orders, i);
                            break;
                        };
                        i = i + 1;
                    };
                };
                table::add(&mut manager.receipts, linked_order_id, linked_receipt);
            };

            // Update filled order status
            let mut filled_receipt_mut = table::remove(&mut manager.receipts, filled_order_id);
            filled_receipt_mut.is_active = false;
            filled_receipt_mut.is_fully_filled = true;
            table::add(&mut manager.receipts, filled_order_id, filled_receipt_mut);

            // Remove filled order from active orders
            let mut i = 0;
            let len = vector::length(&manager.active_orders);
            while (i < len) {
                if (*vector::borrow(&manager.active_orders, i) == filled_order_id) {
                    vector::remove(&mut manager.active_orders, i);
                    break;
                };
                i = i + 1;
            };

            // Emit OCO filled event
            event::emit(OCOOrderFilledEvent {
                oco_group_id,
                filled_order_id,
                cancelled_order_id: linked_order_id,
                user: manager.owner,
                filled_at: cancelled_at,
            });
        }
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
        assert!(vector::contains(&manager.active_orders, &order_id), EORDER_NOT_FOUND);

        let cancelled_at = clock::timestamp_ms(clock);

        // Extract OCO group ID and remove receipt
        let (oco_group_id_option, mut receipt_data) = {
            let receipt = table::remove(&mut manager.receipts, order_id);
            assert!(receipt.is_active, EORDER_ALREADY_CANCELLED);
            assert!(cancelled_at > receipt.created_at, ETIMESTAMP_INVALID);
            (receipt.oco_group_id, receipt)
        };

        // Handle OCO cancellation (cancel linked order if exists)
        if (option::is_some(&oco_group_id_option)) {
            let oco_group_id = *option::borrow(&oco_group_id_option);
            if (table::contains(&manager.oco_groups, oco_group_id)) {
                let linked_order_id = {
                    let mut oco_group = table::remove(&mut manager.oco_groups, oco_group_id);
                    let linked_id = if (oco_group.order1_id == order_id) {
                        oco_group.order2_id
                    } else {
                        oco_group.order1_id
                    };
                    oco_group.is_active = false;
                    table::add(&mut manager.oco_groups, oco_group_id, oco_group);
                    linked_id
                };

                // Cancel linked order if it exists
                if (table::contains(&manager.receipts, linked_order_id)) {
                    let mut linked_receipt = table::remove(&mut manager.receipts, linked_order_id);
                    if (linked_receipt.is_active && vector::contains(&manager.active_orders, &linked_order_id)) {
                        linked_receipt.is_active = false;
                        linked_receipt.cancelled_at = option::some(cancelled_at);

                        // Remove linked order from active orders
                        let mut i = 0;
                        let len = vector::length(&manager.active_orders);
                        while (i < len) {
                            if (*vector::borrow(&manager.active_orders, i) == linked_order_id) {
                                vector::remove(&mut manager.active_orders, i);
                                break;
                            };
                            i = i + 1;
                        };

                        // Emit OCO cancellation event
                        event::emit(OCOOrderCancelledEvent {
                            oco_group_id,
                            cancelled_order_id: linked_order_id,
                            user: manager.owner,
                            cancelled_at,
                        });
                    };
                    table::add(&mut manager.receipts, linked_order_id, linked_receipt);
                }
            }
        };

        // Update receipt data
        receipt_data.is_active = false;
        receipt_data.cancelled_at = option::some(cancelled_at);
        table::add(&mut manager.receipts, order_id, receipt_data);

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

    /// Place TIF (Time-in-Force) limit order with asset refund support
    public fun place_limit_order_tif(
        manager: &mut OrderManager,
        pool_id: vector<u8>,
        price: u64,
        quantity: u64,
        is_bid: bool,
        tif_type: u8,
        mut base_coin: Coin<u64>, // TODO: Replace with actual DeepBook BaseCoinType
        mut quote_coin: Coin<u64>, // TODO: Replace with actual DeepBook QuoteCoinType
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, Option<Coin<u64>>, Option<Coin<u64>>) { // TODO: Replace with actual DeepBook coin types
        // Security and validation checks
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(!manager.is_paused, ECONTRACT_PAUSED);
        assert!(price > 0, EINVALID_PRICE);
        assert!(quantity > 0, EINVALID_QUANTITY);
        assert!(tif_type == IOC || tif_type == FOK, EINVALID_TIF_TYPE);

        let created_at = clock::timestamp_ms(clock);
        assert!(created_at > manager.created_at, ETIMESTAMP_INVALID);

        let order_id = created_at + manager.total_orders_created;

        // DeepBook v3 Integration - Real Implementation Required
        let deepbook_order_id = order_id; // This must be replaced with actual DeepBook v3 order ID

        // CRITICAL: Replace with real DeepBook v3 API calls:
        // let (deepbook_order_id, filled_quantity, remaining_quantity) = deepbook_v3::place_limit_order(
        //     pool, base_coin, quote_coin, price, quantity, is_bid,
        //     if (tif_type == IOC) IMMEDIATE_OR_CANCEL
        //     else if (tif_type == FOK) FILL_OR_KILL
        //     else NO_RESTRICTION,
        //     clock, ctx
        // );

        // Temporary values - MUST BE REPLACED with real DeepBook response
        let filled_quantity = 0;
        let remaining_quantity = quantity;

        // Remove the problematic coin creation - handle refunds in the logic below

        let mut is_active = true;
        let mut is_fully_filled = false;
        let mut refund_base_coin: Option<Coin<u64>> = option::none();
        let mut refund_quote_coin: Option<Coin<u64>> = option::none();

        // Handle TIF logic based on actual DeepBook execution
        if (tif_type == IOC) {
            // IOC: Immediate-or-Cancel - partial fills allowed
            if (remaining_quantity > 0) {
                is_active = false; // Cancel unfilled portion
                // Calculate proportional refund of base coin
                let refund_amount = (remaining_quantity as u128) * (coin::value(&base_coin) as u128) / (quantity as u128);
                let base_coin_refund = coin::split(&mut base_coin, refund_amount as u64, ctx);
                let quote_coin_refund = coin::zero<u64>(ctx); // Quote coin would be used for fees

                // Properly handle option assignments by destroying existing values first
                if (option::is_some(&refund_base_coin)) {
                    let old_coin = option::extract(&mut refund_base_coin);
                    coin::destroy_zero(old_coin);
                };
                if (option::is_some(&refund_quote_coin)) {
                    let old_coin = option::extract(&mut refund_quote_coin);
                    coin::destroy_zero(old_coin);
                };

                option::fill(&mut refund_base_coin, base_coin_refund);
                option::fill(&mut refund_quote_coin, quote_coin_refund);

                // Emit partial fill event
                event::emit(OrderPartialFilledEvent {
                    order_id,
                    filled_quantity,
                    remaining_quantity,
                    user: manager.owner,
                    filled_at: created_at,
                });
            } else {
                is_fully_filled = true;
                is_active = false;
            }
        } else if (tif_type == FOK) {
            // FOK: Fill-or-Kill - must be fully filled or cancelled entirely
            if (remaining_quantity > 0) {
                // FOK failed - refund all coins and cancel order
                is_active = false;
                // Get the base coin value before splitting to avoid referential transparency issue
                let base_coin_value = coin::value(&base_coin);
                // Refund all base coin
                let base_coin_refund = coin::split(&mut base_coin, base_coin_value, ctx);
                let quote_coin_refund = coin::zero<u64>(ctx); // Quote coin would be used for fees

                // Properly handle option assignments by destroying existing values first
                if (option::is_some(&refund_base_coin)) {
                    let old_coin = option::extract(&mut refund_base_coin);
                    coin::destroy_zero(old_coin);
                };
                if (option::is_some(&refund_quote_coin)) {
                    let old_coin = option::extract(&mut refund_quote_coin);
                    coin::destroy_zero(old_coin);
                };

                option::fill(&mut refund_base_coin, base_coin_refund);
                option::fill(&mut refund_quote_coin, quote_coin_refund);

                event::emit(OrderExpiredEvent {
                    order_id,
                    user: manager.owner,
                    expired_at: created_at,
                });

                // Consume any remaining base_coin and quote_coin before returning
                if (coin::value(&base_coin) > 0) {
                    transfer::public_transfer(base_coin, tx_context::sender(ctx));
                } else {
                    coin::destroy_zero(base_coin);
                };

                if (coin::value(&quote_coin) > 0) {
                    transfer::public_transfer(quote_coin, tx_context::sender(ctx));
                } else {
                    coin::destroy_zero(quote_coin);
                };

                // Return order_id with refund coins, don't store the order
                return (order_id, refund_base_coin, refund_quote_coin)
            } else {
                is_fully_filled = true;
                is_active = false;
            }
        };

        // Only store the order if it's still active (for IOC partial fills)
        if (is_active || (tif_type == IOC && filled_quantity > 0)) {
            vector::push_back(&mut manager.active_orders, order_id);
            manager.total_orders_created = manager.total_orders_created + 1;

            let receipt_data = OrderReceiptData {
                order_id,
                deepbook_order_id, // Track DeepBook order ID for cancellation
                pool_id,
                price,
                quantity: remaining_quantity, // Update to remaining quantity
                original_quantity: quantity,
                is_bid,
                order_type: OrderType { value: TIF },
                time_in_force: TimeInForce { value: tif_type },
                created_at,
                is_active,
                is_fully_filled,
                cancelled_at: if (is_active) option::none() else option::some(created_at),
                oco_group_id: option::none(),
                expires_at: option::none(),
            };
            table::add(&mut manager.receipts, order_id, receipt_data);

            // Emit TIF-specific event
            event::emit(TIFOrderPlacedEvent {
                order_id,
                tif_type,
                user: manager.owner,
                created_at,
            });

            // Emit standard order event
            event::emit(OrderPlacedEvent {
                order_id,
                pool_id,
                user: manager.owner,
                price,
                quantity,
                is_bid,
                created_at,
            });
        };

        // Consume remaining base coin properly
        if (coin::value(&base_coin) > 0) {
            transfer::public_transfer(base_coin, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(base_coin);
        };

        // Consume remaining quote coin properly
        if (coin::value(&quote_coin) > 0) {
            transfer::public_transfer(quote_coin, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(quote_coin);
        };

        // Return order_id and any refund coins
        (order_id, refund_base_coin, refund_quote_coin)
    }

    /// DEPRECATED: Function removed per audit requirement - NO MOCKING ALLOWED
    /// Real implementation must use actual DeepBook v3 APIs with order restrictions:
    /// - place_limit_order with IMMEDIATE_OR_CANCEL for IOC
    /// - place_limit_order with FILL_OR_KILL for FOK
    /// - place_limit_order with NO_RESTRICTION for standard orders
    /// Migrate to DeepBook v3 SDK for actual order placement and execution status.

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

    /// Create an owned OrderReceipt object from existing order
    public fun create_order_receipt(
        manager: &mut OrderManager,
        order_id: u64,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(table::contains(&manager.receipts, order_id), EORDER_NOT_FOUND);

        let order_data = table::remove(&mut manager.receipts, order_id);

        let order_receipt = OrderReceipt {
            id: object::new(ctx),
            order_data,
            owner: manager.owner,
        };

        transfer::public_transfer(order_receipt, manager.owner);
    }

    /// Cancel order using owned OrderReceipt object and refund remaining coins
    public fun cancel_order_by_object(
        manager: &mut OrderManager,
        order_receipt: OrderReceipt,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (coin::Coin<u64>, coin::Coin<u64>) {
        // Ownership is verified by Sui runtime - only owner can pass this object
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);
        assert!(!manager.is_paused, ECONTRACT_PAUSED);
        assert!(order_receipt.owner == manager.owner, EUNAUTHORIZED);

        let order_id = order_receipt.order_data.order_id;
        let cancelled_at = clock::timestamp_ms(clock);

        // Update order data to reflect cancellation
        let mut order_data = order_receipt.order_data;
        order_data.is_active = false;
        order_data.cancelled_at = option::some(cancelled_at);

        // CRITICAL: Real DeepBook cancellation implementation required
        // For now, return empty coins - implement real DeepBook cancellation to prevent asset loss
        let base_coin_refund = coin::zero<u64>(ctx);
        let quote_coin_refund = coin::zero<u64>(ctx);

        // TODO: Implement real DeepBook cancellation:
        // if (table::contains(&manager.deepbook_pools, &order_data.pool_id)) {
        //     let pool_uid = table::borrow(&manager.deepbook_pools, &order_data.pool_id);
        //     deepbook::cancel_order(pool, order_data.deepbook_order_id, account_cap);
        //     // Refund actual remaining coins from DeepBook pool
        // }

        // Remove from active orders if it was there
        let mut i = 0;
        let len = vector::length(&manager.active_orders);
        while (i < len) {
            if (*vector::borrow(&manager.active_orders, i) == order_id) {
                vector::remove(&mut manager.active_orders, i);
                break
            };
            i = i + 1;
        };

        // Handle OCO cancellation if applicable
        if (option::is_some(&order_data.oco_group_id)) {
            let oco_group_id = *option::borrow(&order_data.oco_group_id);
            if (table::contains(&manager.oco_groups, oco_group_id)) {
                let oco_group = table::borrow_mut(&mut manager.oco_groups, oco_group_id);
                if (oco_group.is_active) {
                    // Cancel linked order
                    let linked_order_id = if (oco_group.order1_id == order_id) {
                        oco_group.order2_id
                    } else {
                        oco_group.order1_id
                    };

                    if (table::contains(&manager.receipts, linked_order_id)) {
                        let mut linked_receipt = table::remove(&mut manager.receipts, linked_order_id);
                        if (linked_receipt.is_active) {
                            linked_receipt.is_active = false;
                            linked_receipt.cancelled_at = option::some(cancelled_at);

                            // Remove linked order from active orders
                            let mut j = 0;
                            let active_len = vector::length(&manager.active_orders);
                            while (j < active_len) {
                                if (*vector::borrow(&manager.active_orders, j) == linked_order_id) {
                                    vector::remove(&mut manager.active_orders, j);
                                    break;
                                };
                                j = j + 1;
                            };

                            event::emit(OCOOrderCancelledEvent {
                                oco_group_id,
                                cancelled_order_id: linked_order_id,
                                user: manager.owner,
                                cancelled_at,
                            });
                        };
                        table::add(&mut manager.receipts, linked_order_id, linked_receipt);
                    }
                };
                let mut oco_group_obj = table::remove(&mut manager.oco_groups, oco_group_id);
                oco_group_obj.is_active = false;
                table::add(&mut manager.oco_groups, oco_group_id, oco_group_obj);
            }
        };

        // Put updated order data back to table
        table::add(&mut manager.receipts, order_id, order_data);

        // Emit ownership-based cancellation event
        event::emit(OrderCancelledByOwnerEvent {
            order_id,
            owner: manager.owner,
            cancelled_at,
        });

        // Destroy the OrderReceipt object (it has been processed)
        let OrderReceipt { id: uid, order_data: _, owner: _ } = order_receipt;
        object::delete(uid);

        // Return refunded coins
        (base_coin_refund, quote_coin_refund)
    }

    /// Transfer OrderReceipt ownership to another address
    public fun transfer_order_ownership(
        order_receipt: OrderReceipt,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == order_receipt.owner, EUNAUTHORIZED);

        let order_id = order_receipt.order_data.order_id;

        transfer::public_transfer(order_receipt, recipient);

        event::emit(OrderOwnershipTransferredEvent {
            order_id,
            from: tx_context::sender(ctx),
            to: recipient,
            transferred_at: 0, // Use current timestamp from Clock in real implementation
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

    /// Entry function to create order manager (DeepBook integration pending)
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

    /// Entry function to place OCO limit order
    public entry fun place_limit_order_oco_entry(
        manager: &mut OrderManager,
        pool_id: vector<u8>,
        order1_price: u64,
        order1_quantity: u64,
        order1_is_bid: bool,
        order2_price: u64,
        order2_quantity: u64,
        order2_is_bid: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        place_limit_order_oco(
            manager,
            pool_id,
            order1_price,
            order1_quantity,
            order1_is_bid,
            order2_price,
            order2_quantity,
            order2_is_bid,
            clock,
            ctx,
        );
    }

    /// Entry function to handle OCO fill with access control
    public entry fun handle_oco_fill_entry(
        manager: &mut OrderManager,
        filled_order_receipt: OrderReceipt, // Require the filled order receipt
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Security: Only the receipt owner can trigger OCO cancellation
        assert!(tx_context::sender(ctx) == filled_order_receipt.owner, EUNAUTHORIZED);
        assert!(!manager.is_paused, ECONTRACT_PAUSED);
        assert!(tx_context::sender(ctx) == manager.owner, EUNAUTHORIZED);

        let filled_order_id = filled_order_receipt.order_data.order_id;

        // Process OCO fill logic
        handle_oco_fill(manager, filled_order_id, clock, ctx);

        // Since the filled order is now complete, destroy the receipt
        let OrderReceipt { id: uid, order_data: _, owner: _ } = filled_order_receipt;
        object::delete(uid);
    }

    /// Entry function to place TIF limit order with coin handling
    public entry fun place_limit_order_tif_entry(
        manager: &mut OrderManager,
        pool_id: vector<u8>,
        price: u64,
        quantity: u64,
        is_bid: bool,
        tif_type: u8,
        mut base_coin: Coin<u64>, // TODO: Replace with actual DeepBook BaseCoinType
        mut quote_coin: Coin<u64>, // TODO: Replace with actual DeepBook QuoteCoinType
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let (order_id, mut refund_base_coin, mut refund_quote_coin) = place_limit_order_tif(
            manager,
            pool_id,
            price,
            quantity,
            is_bid,
            tif_type,
            base_coin,
            quote_coin,
            clock,
            ctx,
        );

        // Transfer any refunded coins back to user
        if (option::is_some(&refund_base_coin)) {
            let base_coin_ref = option::extract(&mut refund_base_coin);
            transfer::public_transfer(base_coin_ref, tx_context::sender(ctx));
        };

        if (option::is_some(&refund_quote_coin)) {
            let quote_coin_ref = option::extract(&mut refund_quote_coin);
            transfer::public_transfer(quote_coin_ref, tx_context::sender(ctx));
        };

        option::destroy_none(refund_base_coin);
        option::destroy_none(refund_quote_coin);
    }

    /// Entry function to create owned order receipt
    public entry fun create_order_receipt_entry(
        manager: &mut OrderManager,
        order_id: u64,
        ctx: &mut TxContext,
    ) {
        create_order_receipt(manager, order_id, ctx);
    }

    /// Entry function to cancel order by object and refund coins
    public entry fun cancel_order_by_object_entry(
        manager: &mut OrderManager,
        order_receipt: OrderReceipt,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let (base_coin_refund, quote_coin_refund) = cancel_order_by_object(manager, order_receipt, clock, ctx);

        // Transfer refunded coins back to user
        if (coin::value(&base_coin_refund) > 0) {
            transfer::public_transfer(base_coin_refund, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(base_coin_refund);
        };

        if (coin::value(&quote_coin_refund) > 0) {
            transfer::public_transfer(quote_coin_refund, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(quote_coin_refund);
        };
    }

    /// Entry function to transfer order ownership
    public entry fun transfer_order_ownership_entry(
        order_receipt: OrderReceipt,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        transfer_order_ownership(order_receipt, recipient, ctx);
    }
}


