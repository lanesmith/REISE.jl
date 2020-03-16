"""
    interval_loop(env, model_kwargs, solver_kwargs, interval, n_interval,
                  start_index, inputfolder, outputfolder)

Given:
- a Gurobi environment `env`
- a dictionary of model keyword arguments `model_kwargs`
- a dictionary of solver keyword arguments `solver_kwargs`
- an interval length `interval` (hours)
- a number of intervals `n_interval`
- a starting index position `start_index`
- a folder path to load all input files from `inputfolder`
- a folder path to write output files to `outputfolder`

Build a model, and run through the intervals, re-building the model and/or
re-setting constraint right-hand-side values as necessary.
"""
function interval_loop(env::Gurobi.Env, model_kwargs::Dict,
                       solver_kwargs::Dict, interval::Int,
                       n_interval::Int, start_index::Int,
                       inputfolder::String, outputfolder::String)
    # Bad (but known) statuses to match against
    numeric_statuses = (
        JuMP.MOI.INFEASIBLE_OR_UNBOUNDED, JuMP.MOI.NUMERICAL_ERROR,
        JuMP.MOI.OTHER_LIMIT)
    infeasible_statuses = (
        JuMP.MOI.INFEASIBLE, JuMP.MOI.INFEASIBLE_OR_UNBOUNDED)
    # Constant parameters
    case = model_kwargs["case"]
    storage = model_kwargs["storage"]
    sets = _make_sets(case, storage)
    storage_enabled = (sets.num_storage > 0)
    # Start looping
    for i in 1:n_interval
        # These must be declared global so that they persist through the loop.
        global m, voi, pg0, storage_e0
        @show ("load_shed_enabled" in keys(model_kwargs))
        @show ("BarHomogeneous" in keys(solver_kwargs))
        interval_start = start_index + (i - 1) * interval
        interval_end = interval_start + interval - 1
        model_kwargs["start_index"] = interval_start
        if i == 1
            # Build a model with no initial ramp constraint
            if storage_enabled
                model_kwargs["storage_e0"] = storage.sd_table.InitialStorage
            end
            m_kwargs = (; (Symbol(k) => v for (k,v) in model_kwargs)...)
            s_kwargs = (; (Symbol(k) => v for (k,v) in solver_kwargs)...)
            m = JuMP.direct_model(Gurobi.Optimizer(env; s_kwargs...))
            m, voi = _build_model(m; m_kwargs...)
        elseif i == 2
            # Build a model with an initial ramp constraint
            model_kwargs["initial_ramp_enabled"] = true
            model_kwargs["initial_ramp_g0"] = pg0
            if storage_enabled
                model_kwargs["storage_e0"] = storage_e0
            end
            m_kwargs = (; (Symbol(k) => v for (k,v) in model_kwargs)...)
            s_kwargs = (; (Symbol(k) => v for (k,v) in solver_kwargs)...)
            m = JuMP.direct_model(Gurobi.Optimizer(env; s_kwargs...))
            m, voi = _build_model(m; m_kwargs...)
        else
            # Reassign right-hand-side of constraints to match profiles
            bus_demand = _make_bus_demand(case, interval_start, interval_end)
            simulation_hydro = permutedims(Matrix(
                case.hydro[interval_start:interval_end, 2:end]))
            simulation_solar = permutedims(Matrix(
                case.solar[interval_start:interval_end, 2:end]))
            simulation_wind = permutedims(Matrix(
                case.wind[interval_start:interval_end, 2:end]))
            for t in 1:interval, b in sets.load_bus_idx
                JuMP.set_normalized_rhs(
                    voi.powerbalance[b, t], bus_demand[b, t])
            end
            if (("load_shed_enabled" in keys(model_kwargs))
                && (model_kwargs["load_shed_enabled"] == true))
                for t in 1:interval, i in 1:length(sets.load_bus_idx)
                    JuMP.set_upper_bound(voi.load_shed[i, t],
                                         bus_demand[sets.load_bus_idx[i], t])
                end
            end
            for t in 1:interval, g in 1:sets.num_hydro
                JuMP.set_normalized_rhs(
                    voi.hydro_fixed[g, t], simulation_hydro[g, t])
            end
            for t in 1:interval, g in 1:sets.num_solar
                JuMP.set_normalized_rhs(
                    voi.solar_max[g, t], simulation_solar[g, t])
            end
            for t in 1:interval, g in 1:sets.num_wind
                JuMP.set_normalized_rhs(
                    voi.wind_max[g, t], simulation_wind[g, t])
            end
            # Re-assign right-hand-side for initial conditions
            noninf_ramp_idx = findall(case.gen_ramp30 .!= Inf)
            for g in noninf_ramp_idx
                rhs = case.gen_ramp30[g] * 2 + pg0[g]
                JuMP.set_normalized_rhs(voi.initial_rampup[g], rhs)
                rhs = case.gen_ramp30[g] * 2 - pg0[g]
                JuMP.set_normalized_rhs(voi.initial_rampdown[g], rhs)
            end
            if storage_enabled
                for s in 1:sets.num_storage
                    JuMP.set_normalized_rhs(voi.initial_soc[s], storage_e0[s])
                end
            end
        end

        while true
            global results
            # Solve the model, flushing before/after for proper stdout order
            flush(stdout)
            JuMP.optimize!(m)
            flush(stdout)
            status = JuMP.termination_status(m)
            if status == JuMP.MOI.OPTIMAL
                f = JuMP.objective_value(m)
                results = get_results(f, voi, model_kwargs["case"])
                break
            elseif ((status in numeric_statuses)
                    & !("BarHomogeneous" in keys(solver_kwargs)))
                # if BarHomogeneous is not enabled, enable it and re-build
                solver_kwargs["BarHomogeneous"] = 1
                println("enable BarHomogeneous")
                JuMP.set_parameter(m, "BarHomogeneous", 1)
            elseif ((status in infeasible_statuses)
                    & !("load_shed_enabled" in keys(model_kwargs)))
                # if load shed not enabled, enable it and re-build the model
                model_kwargs["load_shed_enabled"] = true
                m_kwargs = (; (Symbol(k) => v for (k,v) in model_kwargs)...)
                s_kwargs = (; (Symbol(k) => v for (k,v) in solver_kwargs)...)
                println("rebuild with load shed")
                m = JuMP.direct_model(Gurobi.Optimizer(env; s_kwargs...))
                m, voi = _build_model(m; m_kwargs...)
            elseif !("BarHomogeneous" in keys(solver_kwargs))
                # if BarHomogeneous is not enabled, enable it and re-build
                solver_kwargs["BarHomogeneous"] = 1
                println("enable BarHomogeneous")
                JuMP.set_parameter(m, "BarHomogeneous", 1)
            elseif !("load_shed_enabled" in keys(model_kwargs))
                model_kwargs["load_shed_enabled"] = true
                m_kwargs = (; (Symbol(k) => v for (k,v) in model_kwargs)...)
                s_kwargs = (; (Symbol(k) => v for (k,v) in solver_kwargs)...)
                println("rebuild with load shed")
                m = JuMP.direct_model(Gurobi.Optimizer(env; s_kwargs...))
                m, voi = _build_model(m; m_kwargs...)
            else
                # Something has gone very wrong
                @show status
                @show keys(model_kwargs)
                @show keys(solver_kwargs)
                @show JuMP.objective_value(m)
                if (("load_shed_enabled" in keys(model_kwargs))
                    && (model_kwargs["load_shed_enabled"] == true))
                    # Display where load shedding is occurring
                    load_shed_values = JuMP.value.(voi.load_shed)
                    load_shed_indices = findall(load_shed_values .> 1e-6)
                    if length(load_shed_indices) > 0
                        @show load_shed_indices
                        @show load_shed_values[load_shed_indices]
                        @show sum(load_shed_values[load_shed_indices])
                    end
                end
                error("Unknown status code!")
            end
        end
        
        # Save initial conditions for next interval
        pg0 = results.pg[:,end]
        if storage_enabled
            storage_e0 = results.storage_e[:,end]
        end
        
        # Save results
        results_filename = "result_" * string(i-1) * ".mat"
        results_filepath = joinpath(outputfolder, results_filename)
        save_results(results, results_filepath)
    end
end