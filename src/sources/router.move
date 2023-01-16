/// # Module-level documentation sections
///
/// * [Background](#Background)
/// * [Implementation](#Implementation)
/// * [Basic public functions](#Basic-public-functions)
/// * [Traversal](#Traversal)
///
/// # Background
///
/// router for orderbook and AMM
/// 
module sea::router {
    use std::signer::address_of;
    use std::vector;
    // use std::debug;
    use aptos_framework::coin::{Self, Coin};

    use sea_spot::lp::{LP};
    
    use sea::amm;
    use sea::escrow;
    use sea::utils;
    use sea::fee;
    use sea::market;
    
    const BUY:                u8   = 1;
    const SELL:               u8   = 2;
    const SIDE_ALL:           u8   = 3;

    const E_NO_AUTH:                              u64 = 100;
    const E_POOL_NOT_EXIST:                       u64 = 7000;
    const E_INSUFFICIENT_BASE_AMOUNT:             u64 = 7001;
    const E_INSUFFICIENT_QUOTE_AMOUNT:            u64 = 7002;
    const E_INSUFFICIENT_AMOUNT:                  u64 = 7003;
    const E_INVALID_AMOUNT_OUT:                   u64 = 7004;
    const E_INVALID_AMOUNT_IN:                    u64 = 7005;
    const E_INSUFFICIENT_LIQUIDITY:               u64 = 7006;
    const E_INSUFFICIENT_QUOTE_RESERVE:           u64 = 7007;
    const E_INSUFFICIENT_BASE_RESERVE:            u64 = 7008;
    const E_INSUFFICIENT_AMOUNT_OUT:              u64 = 7009;
    const E_NON_ZERO_COIN:                        u64 = 7010;
    const E_EMPTY_POOL:                           u64 = 7011;

    // hybrid swap
    public entry fun hybrid_swap_entry<B, Q>(
        account: &signer,
        side: u8,
        amm_base_qty: u64,  // buy: this is amm base out; sell: is is amm base in
        amm_quote_vol: u64,  // buy: this is quote in; sell: this is amm quote out
        ob_base_qty: u64,   // order book base qty
        ob_quote_vol: u64,   // order book quote qty
        slip_out: u64, // slippage min out quote volume
    ) {
        let addr = address_of(account);

        let (base_out, quote_out) = if (side == BUY) {
            hybrid_swap<B, Q>(
                addr,
                side,
                amm_base_qty,
                amm_quote_vol,
                coin::zero(),
                coin::withdraw(account, amm_quote_vol),
                market::new_order<B, Q>(account, side, ob_base_qty, ob_quote_vol, 0, 0),
            )
        } else {
            hybrid_swap<B, Q>(
                addr,
                side,
                amm_base_qty,
                amm_quote_vol,
                coin::withdraw(account, amm_base_qty),
                coin::zero(),
                market::new_order<B, Q>(account, side, ob_base_qty, ob_quote_vol, 0, 0),
            )
        };

        if (side == BUY) {
            // debug::print(&coin::value(&base_out));
            // taker got base
            assert!(coin::value(&base_out) >= slip_out, E_INSUFFICIENT_AMOUNT_OUT);
            utils::register_coin_if_not_exist<B>(account);
        } else {
            // debug::print(&coin::value(&quote_out));
            // taker got quote
            assert!(coin::value(&quote_out) >= slip_out, E_INSUFFICIENT_AMOUNT_OUT);
            utils::register_coin_if_not_exist<Q>(account);
        };

        let addr = address_of(account);
        coin::deposit(addr, base_out);
        coin::deposit(addr, quote_out);
    }

    // hybrid swap
    public entry fun hybrid_swap_auto_entry<B, Q>(
        account: &signer,
        side: u8,
        qty: u64,  // if side is BUY, this is quote amount; if side is SELL, this is base amoount
        slip_out: u64, // slippage min out quote volume
    ) {
        let (amm_base_qty, amm_quote_qty, ob_base_qty, ob_quote_vol) = calc_hybrid_partial<B, Q>(side, qty);

        hybrid_swap_entry<B, Q>(account, side, amm_base_qty, amm_quote_qty, ob_base_qty, ob_quote_vol,slip_out);
    }

    public entry fun add_liquidity<B, Q>(
        account: &signer,
        amt_base_desired: u64,
        amt_quote_desired: u64,
        amt_base_min: u64,
        amt_quote_min: u64
    ) {
        assert!(amm::pool_exist<B, Q>(), E_POOL_NOT_EXIST);

        let (amount_base,
            amount_quote) = amm::calc_optimal_coin_values<B, Q>(
                amt_base_desired,
                amt_quote_desired,
                amt_base_min,
                amt_quote_min);
        let coin_base = coin::withdraw<B>(account, amount_base);
        let coin_quote = coin::withdraw<Q>(account, amount_quote);
        let lp_coins = amm::mint<B, Q>(coin_base, coin_quote);

        let acc_addr = address_of(account);
        utils::register_coin_if_not_exist<LP<B, Q>>(account);
        coin::deposit(acc_addr, lp_coins);
    }

    public entry fun remove_liquidity<B, Q>(
        account: &signer,
        liquidity: u64,
        amt_base_min: u64,
        amt_quote_min: u64,
    ) {
        assert!(amm::pool_exist<B, Q>(), E_POOL_NOT_EXIST);
        let coins = coin::withdraw<LP<B, Q>>(account, liquidity);
        let (base_out, quote_out) = amm::burn<B, Q>(coins);

        assert!(coin::value(&base_out) >= amt_base_min, E_INSUFFICIENT_BASE_AMOUNT);
        assert!(coin::value(&quote_out) >= amt_quote_min, E_INSUFFICIENT_QUOTE_AMOUNT);

        // transfer
        let account_addr = address_of(account);
        coin::deposit(account_addr, base_out);
        coin::deposit(account_addr, quote_out);
    }

    // user: buy exact quote
    // amount_out: quote amount out of pool
    // amount_in_max: base amount into pool
    public entry fun buy_exact_quote<B, Q>(
        account: &signer,
        amount_out: u64,
        amount_in_max: u64
        ) {
        let coin_in_needed = get_amount_in<B, Q>(amount_out, false);
        assert!(coin_in_needed <= amount_in_max, E_INSUFFICIENT_BASE_AMOUNT);
        let coin_in = coin::withdraw<B>(account, coin_in_needed);
        let coin_out;
        coin_out = swap_base_for_quote<B, Q>(coin_in, amount_out);
        utils::register_coin_if_not_exist<Q>(account);
        coin::deposit<Q>(address_of(account), coin_out);
    }

    // user: sell base
    public entry fun sell_exact_base<B, Q>(
        account: &signer,
        amount_in: u64,
        amount_out_min: u64
        ) {
        let coin_in = coin::withdraw<B>(account, amount_in);
        let coin_out;
        coin_out = swap_base_for_quote<B, Q>(coin_in, amount_out_min);
        assert!(coin::value(&coin_out) >= amount_out_min, E_INSUFFICIENT_QUOTE_AMOUNT);
        utils::register_coin_if_not_exist<Q>(account);
        coin::deposit<Q>(address_of(account), coin_out);
    }

    // user: buy base
    // amount_out: the exact base amount
    public entry fun buy_exact_base<B, Q>(
        account: &signer,
        amount_out: u64,
        amount_in_max: u64
        ) {
        let coin_in_needed = get_amount_in<B, Q>(amount_out, true);
        assert!(coin_in_needed <= amount_in_max, E_INSUFFICIENT_BASE_AMOUNT);
        let coin_in = coin::withdraw<Q>(account, coin_in_needed);
        let coin_out;
        coin_out = swap_quote_for_base<B, Q>(coin_in, amount_out);
        utils::register_coin_if_not_exist<B>(account);
        coin::deposit<B>(address_of(account), coin_out);
    }

    // user: sell exact quote
    public entry fun sell_exact_quote<B, Q>(
        account: &signer,
        amount_in: u64,
        amount_out_min: u64
        ) {
        let coin_in = coin::withdraw<Q>(account, amount_in);
        let coin_out;
        coin_out = swap_quote_for_base<B, Q>(coin_in, amount_out_min);
        assert!(coin::value(&coin_out) >= amount_out_min, E_INSUFFICIENT_QUOTE_AMOUNT);
        utils::register_coin_if_not_exist<B>(account);
        coin::deposit<B>(address_of(account), coin_out);
    }

    public entry fun withdraw_dao_fee<B, Q>(
        account: &signer,
        to: address
    ) {
        assert!(address_of(account) == @sea, E_NO_AUTH);

        let amount = coin::balance<LP<B, Q>>(@sea_spot) - amm::get_min_liquidity();
        assert!(amount > 0, E_INSUFFICIENT_AMOUNT);
        coin::transfer<LP<B, Q>>(&escrow::get_spot_account(), to, amount);
    }

    ////////////////////////////////////////////////////////////////////////////
    /// PUBLIC FUNCTIONS
    ////////////////////////////////////////////////////////////////////////////
    
    // use orderbook match price better than amm, until end
    // return: amm_base_qty amm_quote_vol ob_base_qty ob_quote_vol
    public fun calc_hybrid_partial<B, Q>(
        side: u8,
        qty: u64,
    ): (u64, u64, u64, u64) {
        let steps = market::get_pair_side_steps<B, Q>(SIDE_ALL - side);
        // first, check the orderbook's price is 
        if (vector::length(&steps) == 0) {
            // all use amm
            if (side == BUY) {
                return (get_amount_out<B, Q>(qty, false), qty, 0, 0)
            } else {
                return (qty, get_amount_out<B, Q>(qty, true), 0, 0)
            }
        };
        let (base_reserve, quote_reserve, amm_fee_ratio) = amm::get_pool_reserve_fee_u128<B, Q>();
        assert!(base_reserve > 0 && quote_reserve > 0, E_EMPTY_POOL);
        let (price_ratio, _, lot_size) = market::get_pair_info_u128<B, Q>();
        let amm_fee_deno = (fee::get_fee_denominate() as u128);

        let i = 0;
        let ob_base_qty = 0;
        let ob_quote_vol = 0;
        let qty_u128 = (qty as u128);
        let amm_best_price: u128 = base_reserve * price_ratio / quote_reserve;
        let (amm_base_qty, amm_quote_vol, amm_worst_price) = get_amm_price(
            side,
            qty_u128,
            price_ratio,
            base_reserve,
            quote_reserve,
            amm_fee_ratio,
            amm_fee_deno,
        );

        while(i < vector::length(&steps)) {
            let step = vector::borrow(&steps, i);
            let (step_price, step_qty) = market::get_price_step_u128(step);
            // if step_qty 
            let step_quote = utils::calc_quote_qty_u128(step_qty, step_price, price_ratio);
            if (side == BUY) {
                if (step_price >= amm_worst_price) {
                    break
                };
                if (step_price < amm_best_price) {
                    i = i + 1;
                    ob_base_qty = ob_base_qty + step_qty;
                    ob_quote_vol = ob_quote_vol + step_quote;
                    continue
                };
                if (ob_quote_vol + step_quote >= qty_u128) 
                    step_qty = (qty_u128 - ob_quote_vol) / lot_size * lot_size;
            } else if (side == SELL) {
                if (step_price <= amm_worst_price) {
                    break
                };
                if (step_price > amm_best_price) {
                    i = i + 1;
                    ob_base_qty = ob_base_qty + step_qty;
                    ob_quote_vol = ob_quote_vol + step_quote;
                    continue
                };
                if (step_qty + ob_base_qty >= qty_u128)
                    step_qty = (qty_u128 - ob_quote_vol) / lot_size * lot_size;
            };
            if (step_qty == 0) break;
            // step_quote = utils::calc_quote_qty_u128(step_qty, (step_price as u128), price_ratio);

            let step_base_qty;
            let step_quote_vol;
            (amm_base_qty, amm_quote_vol, step_base_qty, step_quote_vol) = get_clob_qty(
                side,
                step_price,
                qty_u128,
                ob_base_qty,
                lot_size,
                step_qty,
                price_ratio,
                base_reserve,
                quote_reserve,
                amm_fee_ratio,
                amm_fee_deno,
            );
            ob_base_qty = ob_base_qty + step_base_qty;
            ob_quote_vol = ob_quote_vol + step_quote_vol;
            i = i + 1;
        };

        ((amm_base_qty as u64), (amm_quote_vol as u64), (ob_base_qty as u64), (ob_quote_vol as u64))
    }

    public fun get_amm_price(
        side: u8,
        qty: u128,
        price_ratio: u128,
        base_reserve: u128,
        quote_reserve: u128,
        fee_ratio: u128,
        fee_deno: u128,
    ): (u128, u128, u128) {
        let amount_in_with_fee = qty * (fee_deno - fee_ratio);
        if (side == SELL) {
            let numerator = amount_in_with_fee * base_reserve;
            let denominator = quote_reserve * fee_deno + amount_in_with_fee;
            let base_out = numerator / denominator;
            (base_out, qty, ((qty * price_ratio) / base_out))
        } else {
            let numerator = amount_in_with_fee * quote_reserve;
            let denominator = base_reserve * fee_deno + amount_in_with_fee;
            let quote_out = numerator / denominator;
            (qty, quote_out, ((quote_out * price_ratio) / qty))
        }
    }

    // compare is amm price is better than orderbook price
    // price is orderbook maker price
    // return: step_base_qty, step_quote_vol, step_amm_price
    fun get_clob_qty(
        side: u8,
        price: u128,
        qty: u128,
        total_ob_qty: u128,
        lot_size: u128,
        step_base_qty: u128,    // order book step base qty
        price_ratio: u128,
        base_reserve: u128,
        quote_reserve: u128,
        amm_fee_ratio: u128,
        amm_fee_deno: u128,
    ): (u128, u128, u128, u128) {
        let amm_base_qty: u128;
        let amm_quote_vol: u128;
        let amm_step_price: u128;
        let step_quote_vol: u128;
        // let complete = false;

        loop {
            if (side == BUY) {
                // qty is quote in
                // get_amount_out
                step_quote_vol = utils::calc_quote_qty_u128(step_base_qty, (price as u128), price_ratio);
                amm_quote_vol = (qty - total_ob_qty - step_quote_vol);
                let amount_in_with_fee = amm_quote_vol * (amm_fee_deno - amm_fee_ratio);
                let numerator = amount_in_with_fee * base_reserve;
                let denominator = quote_reserve * amm_fee_deno + amount_in_with_fee;
                amm_base_qty = numerator / denominator;
                amm_step_price = ((amm_base_qty * price_ratio) / amm_quote_vol);

                // amm price is better, stop
                if (amm_step_price <= price) break;
            } else {
                // qty is base in
                amm_base_qty = (qty - total_ob_qty - step_base_qty);
                let amount_in_with_fee = amm_base_qty * (amm_fee_deno - amm_fee_ratio);
                let numerator = amount_in_with_fee * quote_reserve;
                let denominator = base_reserve * amm_fee_deno + amount_in_with_fee;
                amm_quote_vol = numerator / denominator;
                amm_step_price = ((amm_quote_vol * price_ratio) / amm_base_qty);

                step_quote_vol = utils::calc_quote_qty_u128(step_base_qty, (price as u128), price_ratio);
                if (amm_step_price >= price) break;
            };

            step_base_qty = (step_base_qty / 2) / lot_size * lot_size;
            if (step_base_qty == 0) break;
        };

        (amm_base_qty, amm_quote_vol, step_base_qty, step_quote_vol)
    }

    public fun hybrid_swap<B, Q>(
        addr: address,
        side: u8,
        amm_base_qty: u64,
        amm_quote_vol: u64,
        amm_base: Coin<B>,
        amm_quote: Coin<Q>,  // buy: this is quote in; sell: this is amm base in
        order: market::OrderEntity<B, Q>,   // order book quote qty
    ): (Coin<B>, Coin<Q>) {
        let base_out = coin::zero<B>();
        let quote_out = coin::zero<Q>();

        if (!market::is_empty_order<B, Q>(&order)) {
            let (_, _, order_left) = market::match_order(addr, side, 0, order, true);
            let (order_base, order_quote) = market::extract_order(order_left);
            coin::merge(&mut base_out, order_base);
            coin::merge(&mut quote_out, order_quote);
        } else {
            market::destroy_order(addr, order);
        };

        if (amm_base_qty > 0 || amm_quote_vol > 0) {
            if (side == BUY) {
                // buy exact base
                // let coin_in = coin::withdraw<Q>(account, amm_quote_vol);
                let coin_out = swap_quote_for_base<B, Q>(amm_quote, amm_base_qty);
                coin::merge(&mut base_out, coin_out);
                coin::merge(&mut base_out, amm_base);
            } else {
                // sell exact base
                // let coin_in = coin::withdraw<B>(account, amm_base_qty);
                let coin_out  = swap_base_for_quote<B, Q>(amm_base, amm_quote_vol);
                coin::merge(&mut quote_out, coin_out);
                coin::merge(&mut quote_out, amm_quote);
            };
        } else {
            assert!(coin::value(&amm_base) == 0, E_NON_ZERO_COIN);
            assert!(coin::value(&amm_quote) == 0, E_NON_ZERO_COIN);
            coin::destroy_zero(amm_base);
            coin::destroy_zero(amm_quote);
        };

        (base_out, quote_out)
    }

    // sell base, buy quote
    public fun swap_base_for_quote<B, Q>(
        coin_in: Coin<B>,
        coin_out_val: u64
    ): Coin<Q> {
        let (zero, coin_out) = amm::swap<B, Q>(coin_in, 0, coin::zero(), coin_out_val);
        coin::destroy_zero(zero);

        coin_out
    }

    // sell quote, buy base
    public fun swap_quote_for_base<B, Q>(
        coin_in: Coin<Q>,
        coin_out_val: u64,
    ): Coin<B> {
        let (coin_out, zero) = amm::swap<B, Q>(coin::zero(), coin_out_val, coin_in, 0);
        coin::destroy_zero(zero);

        coin_out
    }

    /// out_is_base: by user perspective
    public fun get_amount_in<B, Q>(
        amount_out: u64,
        out_is_base: bool,
    ): u64 {
        assert!(amount_out > 0, E_INVALID_AMOUNT_OUT);
        let (base_reserve, quote_reserve, fee_ratio) = amm::get_pool_reserve_fee<B, Q>();
        assert!(base_reserve> 0 && quote_reserve > 0, E_INSUFFICIENT_LIQUIDITY);

        let numerator: u128;
        let denominator: u128;
        let fee_deno = fee::get_fee_denominate();
        if (out_is_base) {
            assert!(base_reserve > amount_out, E_INSUFFICIENT_BASE_RESERVE);
            numerator = (quote_reserve as u128) * (amount_out as u128) * (fee_deno as u128);
            denominator = ((base_reserve - amount_out) as u128) * ((fee_deno - fee_ratio) as u128);
        } else {
            assert!(quote_reserve > amount_out, E_INSUFFICIENT_QUOTE_RESERVE);
            numerator = (base_reserve as u128) * (amount_out as u128) * (fee_deno as u128);
            denominator = ((quote_reserve - amount_out) as u128) * ((fee_deno - fee_ratio) as u128);
        };

        // debug::print(&denominator);
        ((numerator / denominator + 1) as u64)
    }

    public fun get_amount_out<B, Q>(
        amount_in: u64,
        out_is_quote: bool,
    ): u64 {
        assert!(amount_in > 0, E_INVALID_AMOUNT_IN);
        let (base_reserve, quote_reserve, fee_ratio) = amm::get_pool_reserve_fee<B, Q>();
        assert!(base_reserve > 0 && quote_reserve > 0, E_INSUFFICIENT_LIQUIDITY);

        let fee_deno = fee::get_fee_denominate();
        let amount_in_with_fee = (amount_in as u128) * ((fee_deno - fee_ratio) as u128);
        let numerator: u128;
        let denominator: u128;
        if (out_is_quote) {
            numerator = amount_in_with_fee * (quote_reserve as u128);
            denominator = (base_reserve as u128) * (fee_deno as u128) + amount_in_with_fee;
        } else {
            numerator = amount_in_with_fee * (base_reserve as u128);
            denominator = (quote_reserve as u128) * (fee_deno as u128) + amount_in_with_fee;
        };

        let amount_out = numerator / denominator;
        // debug::print(&amount_out);
        (amount_out as u64)
    }


    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_buy_entry(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            2, // sell
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::withdraw(user2, 120000),
                coin::zero(),
            ),
        );

        let quote_in = get_amount_in<market::T_BTC, market::T_USD>(215000, true);
        // buy
        hybrid_swap_entry<market::T_BTC, market::T_USD>(
            user3,
            1,
            215000,
            quote_in,
            120000,
            120000 * 15120,
            215000+(120000-120000*5/10000),
        );
    }

    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_buy(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            2, // sell
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::withdraw(user2, 120000),
                coin::zero(),
            ),
        );

        let quote_in_vol = get_amount_in<market::T_BTC, market::T_USD>(215000, true);
        let addr3 = address_of(user3);
        let taker_order = market::new_order(
            user3,
            1, // buy
            0,
            120000 * 15120,
            0,
            0,
        );
        // buy
        let (base_out, quote_out) = hybrid_swap<market::T_BTC, market::T_USD>(
            addr3,
            1,
            215000,
            quote_in_vol,
            coin::zero(),
            coin::withdraw(user3, quote_in_vol),
            // 120000,
            // 120000 * 15120,
            taker_order,
            // 215000,
            // quote_in,
            // 120000,
            // 120000 * 15120,
            // 215000+(120000-120000*5/10000),
        );
        assert!(coin::value(&quote_out) == 0, 11);
        coin::destroy_zero(quote_out);
        // debug::print(&coin::value(&base_out));
        assert!(coin::value(&base_out) == 215000 + (120000 - 120000*5/10000), 12);
        coin::deposit(addr3, base_out);
    }

    // swap just use orderbook, taker complete filled
    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_buy_only_orderbook_filled(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            2, // sell
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::withdraw(user2, 120000),
                coin::zero(),
            ),
        );

        // let quote_in_vol = get_amount_in<market::T_BTC, market::T_USD>(215000, true);
        let addr3 = address_of(user3);
        let taker_order = market::new_order(
            user3,
            1, // buy
            0,
            100000 * 15120,
            0,
            0,
        );
        // buy
        let (base_out, quote_out) = hybrid_swap<market::T_BTC, market::T_USD>(
            addr3,
            1,
            0,
            0,
            coin::zero(),
            coin::zero(),
            // 120000,
            // 120000 * 15120,
            taker_order,
            // 215000,
            // quote_in,
            // 120000,
            // 120000 * 15120,
            // 215000+(120000-120000*5/10000),
        );
        assert!(coin::value(&quote_out) == 0, 11);
        coin::destroy_zero(quote_out);
        // debug::print(&coin::value(&base_out));
        assert!(coin::value(&base_out) == (100000 - 100000*5/10000), 12);
        coin::deposit(addr3, base_out);
    }

    // swap just use orderbook, taker partial filled
    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_buy_only_orderbook_partial(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            2, // sell
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::withdraw(user2, 120000),
                coin::zero(),
            ),
        );

        // let quote_in_vol = get_amount_in<market::T_BTC, market::T_USD>(215000, true);
        let addr3 = address_of(user3);
        let taker_order = market::new_order(
            user3,
            1, // buy
            0,
            200000 * 15120,
            0,
            0,
        );
        // buy
        let (base_out, quote_out) = hybrid_swap<market::T_BTC, market::T_USD>(
            addr3,
            1,
            0,
            0,
            coin::zero(),
            coin::zero(),
            // 120000,
            // 120000 * 15120,
            taker_order,
            // 215000,
            // quote_in,
            // 120000,
            // 120000 * 15120,
            // 215000+(120000-120000*5/10000),
        );
        assert!(coin::value(&quote_out) == 80000 * 15120, 11);
        coin::deposit(addr3, quote_out);
        // debug::print(&coin::value(&base_out));
        assert!(coin::value(&base_out) == (120000 - 120000*5/10000), 12);
        coin::deposit(addr3, base_out);
    }

    // swap just use amm
    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_buy_only_amm(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            2, // sell
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::withdraw(user2, 120000),
                coin::zero(),
            ),
        );

        let quote_in_vol = get_amount_in<market::T_BTC, market::T_USD>(215000, true);
        let addr3 = address_of(user3);
        let taker_order = market::new_order(
            user3,
            1, // buy
            0,
            0,
            0,
            0,
        );
        // buy
        let (base_out, quote_out) = hybrid_swap<market::T_BTC, market::T_USD>(
            addr3,
            1,
            215000,
            quote_in_vol,
            coin::zero(),
            coin::withdraw(user3, quote_in_vol),
            // 120000,
            // 120000 * 15120,
            taker_order,
            // 215000,
            // quote_in,
            // 120000,
            // 120000 * 15120,
            // 215000+(120000-120000*5/10000),
        );
        assert!(coin::value(&quote_out) == 0, 11);
        coin::destroy_zero(quote_out);
        // debug::print(&coin::value(&base_out));
        assert!(coin::value(&base_out) == 215000, 12);
        coin::deposit(addr3, base_out);
    }

    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_sell_entry(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            1, // buy
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::zero(),
                coin::withdraw(user2, 120000*15120),
            ),
        );

        let quote_out = get_amount_out<market::T_BTC, market::T_USD>(215000, true);
        // debug::print(&quote_out);
        // sell
        hybrid_swap_entry<market::T_BTC, market::T_USD>(
            user3,
            2,
            215000,
            quote_out,
            120000,
            120000 * 15120,
            quote_out+(120000-120000*5/10000)*15120,
        );
    }

    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_sell(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            1, // buy
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::zero(),
                coin::withdraw(user2, 120000*15120),
            ),
        );

        let quote_out_vol = get_amount_out<market::T_BTC, market::T_USD>(215000, true);
        let addr3 = address_of(user3);
        let taker_order = market::new_order(
            user3,
            2, // sell
            120000,
            0,
            0,
            0,
        );
            // quote_out+(120000-120000*5/10000)*15120);
        // debug::print(&quote_out);
        // sell
        let (base_out, quote_out) = hybrid_swap<market::T_BTC, market::T_USD>(
            addr3,
            2,
            215000,
            quote_out_vol,
            coin::withdraw(user3, 215000),
            coin::zero(),
            // 120000,
            // 120000 * 15120,
            taker_order,
        );
        assert!(coin::value(&base_out) == 0, 1);
        coin::destroy_zero(base_out);
        let quote_ob_vol = 120000 * 15120;
        let ob_fee = quote_ob_vol * 5 / 10000;
        let quote_ob_net = quote_ob_vol - ob_fee;
        // debug::print(&quote_ob_net);
        // debug::print(&coin::value(&quote_out));
        assert!(coin::value(&quote_out) == quote_out_vol + quote_ob_net, 2);
        coin::deposit(addr3, quote_out);
    }

    // swap just use orderbook
    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_sell_only_orderbook_filled(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            1, // buy
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::zero(),
                coin::withdraw(user2, 120000*15120),
            ),
        );

        // let quote_out_vol = get_amount_out<market::T_BTC, market::T_USD>(215000, true);
        let addr3 = address_of(user3);
        let taker_order = market::new_order(
            user3,
            2, // sell
            100000,
            0,
            0,
            0,
        );
            // quote_out+(120000-120000*5/10000)*15120);
        // debug::print(&quote_out);
        // sell
        let (base_out, quote_out) = hybrid_swap<market::T_BTC, market::T_USD>(
            addr3,
            2,
            0,
            0,
            coin::zero(),
            coin::zero(),
            // 120000,
            // 120000 * 15120,
            taker_order,
        );
        assert!(coin::value(&base_out) == 0, 1);
        coin::destroy_zero(base_out);
        let quote_ob_vol = 100000 * 15120;
        let ob_fee = quote_ob_vol * 5 / 10000;
        let quote_ob_net = quote_ob_vol - ob_fee;
        // debug::print(&quote_ob_net);
        // debug::print(&coin::value(&quote_out));
        assert!(coin::value(&quote_out) == quote_ob_net, 2);
        coin::deposit(addr3, quote_out);
    }

    // swap just use orderbook, taker partial filled
    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_sell_only_orderbook_partial(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            1, // buy
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::zero(),
                coin::withdraw(user2, 120000*15120),
            ),
        );

        // let quote_out_vol = get_amount_out<market::T_BTC, market::T_USD>(215000, true);
        let addr3 = address_of(user3);
        let taker_order = market::new_order(
            user3,
            2, // sell
            200000,
            0,
            0,
            0,
        );
            // quote_out+(120000-120000*5/10000)*15120);
        // debug::print(&quote_out);
        // sell
        let (base_out, quote_out) = hybrid_swap<market::T_BTC, market::T_USD>(
            addr3,
            2,
            0,
            0,
            coin::zero(),
            coin::zero(),
            // 120000,
            // 120000 * 15120,
            taker_order,
        );
        assert!(coin::value(&base_out) == 200000-120000, 1);
        coin::deposit(addr3, base_out);
        let quote_ob_vol = 120000 * 15120;
        let ob_fee = quote_ob_vol * 5 / 10000;
        let quote_ob_net = quote_ob_vol - ob_fee;
        // debug::print(&quote_ob_net);
        // debug::print(&coin::value(&quote_out));
        assert!(coin::value(&quote_out) == quote_ob_net, 2);
        coin::deposit(addr3, quote_out);
    }

    // swap just use amm
    #[test(
        user1 = @user_1,
        user2 = @user_2,
        user3 = @user_3
    )]
    fun test_hybrid_swap_sell_only_amm(
        user1: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        market::test_register_pair(user1, user2, user3);

        add_liquidity<market::T_BTC, market::T_USD>(user1, 100000, 100000 * 15120, 0, 0);
        add_liquidity<market::T_BTC, market::T_USD>(user1, 200000, 200000 * 15120, 0, 0);

        let addr2 = address_of(user2);
        let account_id2 = escrow::get_or_register_account_id(addr2);
        market::do_place_postonly_order<market::T_BTC, market::T_USD>(
            1, // buy
            15120 * 1000000000,
            market::build_order<market::T_BTC, market::T_USD>(
                account_id2,
                0,
                120000,
                coin::zero(),
                coin::withdraw(user2, 120000*15120),
            ),
        );

        // let quote_out_vol = get_amount_out<market::T_BTC, market::T_USD>(215000, true);
        let addr3 = address_of(user3);
        let taker_order = market::new_order(
            user3,
            2, // sell
            200000,
            0,
            0,
            0,
        );
            // quote_out+(120000-120000*5/10000)*15120);
        // debug::print(&quote_out);
        // sell
        let (base_out, quote_out) = hybrid_swap<market::T_BTC, market::T_USD>(
            addr3,
            2,
            0,
            0,
            coin::zero(),
            coin::zero(),
            // 120000,
            // 120000 * 15120,
            taker_order,
        );
        assert!(coin::value(&base_out) == 200000-120000, 1);
        coin::deposit(addr3, base_out);
        let quote_ob_vol = 120000 * 15120;
        let ob_fee = quote_ob_vol * 5 / 10000;
        let quote_ob_net = quote_ob_vol - ob_fee;
        // debug::print(&quote_ob_net);
        // debug::print(&coin::value(&quote_out));
        assert!(coin::value(&quote_out) == quote_ob_net, 2);
        coin::deposit(addr3, quote_out);
    }

    // alloc hybrid swap

    // flash loan
}
