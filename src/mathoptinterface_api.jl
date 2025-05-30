# Copyright (c) 2017: Miles Lubin and contributors
# Copyright (c) 2017: Google Inc.
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

_no_hessian(op::MOI.Nonlinear._UnivariateOperator) = op.f′′ === nothing
_no_hessian(op::MOI.Nonlinear._MultivariateOperator) = op.∇²f === nothing

function MOI.features_available(d::NLPEvaluator)
    # Check if we are missing any hessians for user-defined operators, in which
    # case we need to disable :Hess and :HessVec.
    d.disable_2ndorder =
        any(_no_hessian, d.data.operators.registered_univariate_operators) ||
        any(_no_hessian, d.data.operators.registered_multivariate_operators)
    if d.disable_2ndorder
        return [:Grad, :Jac, :JacVec]
    end
    return [:Grad, :Jac, :JacVec, :Hess, :HessVec]
end

function MOI.initialize(d::NLPEvaluator, requested_features::Vector{Symbol})
    # Check that we support the features requested by the user.
    available_features = MOI.features_available(d)
    for feature in requested_features
        if !(feature in available_features)
            error("Unsupported feature $feature")
        end
    end
    moi_index_to_consecutive_index =
        Dict(x => i for (i, x) in enumerate(d.ordered_variables))
    N = length(moi_index_to_consecutive_index)
    #
    largest_user_input_dimension = 1
    for op in d.data.operators.registered_multivariate_operators
        largest_user_input_dimension = max(largest_user_input_dimension, op.N)
    end
    d.objective = nothing
    d.user_output_buffer = zeros(largest_user_input_dimension)
    d.jac_storage = zeros(max(N, largest_user_input_dimension))
    d.constraints = _FunctionStorage[]
    d.last_x = fill(NaN, N)
    d.want_hess = :Hess in requested_features
    want_hess_storage = (:HessVec in requested_features) || d.want_hess
    coloring_storage = Coloring.IndexedSet(N)
    max_expr_length = 0
    max_expr_with_sub_length = 0
    #
    main_expressions = [c.expression.nodes for (_, c) in d.data.constraints]
    if d.data.objective !== nothing
        pushfirst!(main_expressions, something(d.data.objective).nodes)
    end
    d.subexpression_order, individual_order = _order_subexpressions(
        main_expressions,
        [expr.nodes for expr in d.data.expressions],
    )
    num_subexpressions = length(d.data.expressions)
    d.subexpression_linearity = Vector{Linearity}(undef, num_subexpressions)
    subexpression_variables = Vector{Vector{Int}}(undef, num_subexpressions)
    subexpression_edgelist =
        Vector{Set{Tuple{Int,Int}}}(undef, num_subexpressions)
    d.subexpressions = Vector{_SubexpressionStorage}(undef, num_subexpressions)
    d.subexpression_forward_values = zeros(num_subexpressions)
    d.subexpression_reverse_values = zeros(num_subexpressions)
    for k in d.subexpression_order
        # Only load expressions which actually are used
        d.subexpression_forward_values[k] = NaN
        expr = d.data.expressions[k]
        subex, _ = _subexpression_and_linearity(
            expr,
            moi_index_to_consecutive_index,
            Float64[],
            d,
        )
        d.subexpressions[k] = subex
        d.subexpression_linearity[k] = subex.linearity
        max_expr_with_sub_length =
            max(max_expr_with_sub_length, length(subex.nodes))
        if d.want_hess
            empty!(coloring_storage)
            _compute_gradient_sparsity!(coloring_storage, subex.nodes)
            # union with all dependent expressions
            for idx in _list_subexpressions(subex.nodes)
                union!(coloring_storage, subexpression_variables[idx])
            end
            subexpression_variables[k] = collect(coloring_storage)
            empty!(coloring_storage)
            linearity = _classify_linearity(
                subex.nodes,
                subex.adj,
                d.subexpression_linearity,
            )
            edgelist = _compute_hessian_sparsity(
                subex.nodes,
                subex.adj,
                linearity,
                coloring_storage,
                subexpression_edgelist,
                subexpression_variables,
            )
            subexpression_edgelist[k] = edgelist
        end
    end
    max_chunk = 1
    shared_partials_storage_ϵ = Float64[]
    if d.data.objective !== nothing
        expr = something(d.data.objective)
        subexpr, linearity = _subexpression_and_linearity(
            expr,
            moi_index_to_consecutive_index,
            shared_partials_storage_ϵ,
            d,
        )
        objective = _FunctionStorage(
            subexpr,
            N,
            coloring_storage,
            d.want_hess,
            d.subexpressions,
            individual_order[1],
            subexpression_edgelist,
            subexpression_variables,
            linearity,
        )
        max_expr_length = max(max_expr_length, length(expr.nodes))
        max_chunk = max(max_chunk, size(objective.seed_matrix, 2))
        d.objective = objective
    end
    for (k, (_, constraint)) in enumerate(d.data.constraints)
        idx = d.data.objective !== nothing ? k + 1 : k
        expr = constraint.expression
        subexpr, linearity = _subexpression_and_linearity(
            expr,
            moi_index_to_consecutive_index,
            shared_partials_storage_ϵ,
            d,
        )
        push!(
            d.constraints,
            _FunctionStorage(
                subexpr,
                N,
                coloring_storage,
                d.want_hess,
                d.subexpressions,
                individual_order[idx],
                subexpression_edgelist,
                subexpression_variables,
                linearity,
            ),
        )
        max_expr_length = max(max_expr_length, length(expr.nodes))
        max_chunk = max(max_chunk, size(d.constraints[end].seed_matrix, 2))
    end
    max_chunk = min(max_chunk, MAX_CHUNK)
    max_expr_with_sub_length = max(max_expr_with_sub_length, max_expr_length)
    if d.want_hess || want_hess_storage
        d.input_ϵ = zeros(max_chunk * N)
        d.output_ϵ = zeros(max_chunk * N)
        #
        resize!(shared_partials_storage_ϵ, max_chunk * max_expr_length)
        fill!(shared_partials_storage_ϵ, 0.0)
        d.storage_ϵ = zeros(max_chunk * max_expr_with_sub_length)
        #
        len = max_chunk * length(d.subexpressions)
        d.subexpression_forward_values_ϵ = zeros(len)
        d.subexpression_reverse_values_ϵ = zeros(len)
        #
        for k in d.subexpression_order
            len = max_chunk * length(d.subexpressions[k].nodes)
            resize!(d.subexpressions[k].partials_storage_ϵ, len)
            fill!(d.subexpressions[k].partials_storage_ϵ, 0.0)
        end
        d.max_chunk = max_chunk
        if d.want_hess
            d.hessian_sparsity = Tuple{Int64,Int64}[]
            obj = d.objective
            if obj !== nothing
                append!(d.hessian_sparsity, zip(obj.hess_I, obj.hess_J))
            end
            for c in d.constraints
                append!(d.hessian_sparsity, zip(c.hess_I, c.hess_J))
            end
        end
    end
    return
end

function MOI.eval_objective(d::NLPEvaluator, x)
    if d.objective === nothing
        error("No nonlinear objective.")
    end
    _reverse_mode(d, x)
    return something(d.objective).expr.forward_storage[1]
end

function MOI.eval_objective_gradient(d::NLPEvaluator, g, x)
    if d.objective === nothing
        error("No nonlinear objective.")
    end
    _reverse_mode(d, x)
    fill!(g, 0.0)
    _extract_reverse_pass(g, d, something(d.objective))
    return
end

function MOI.eval_constraint(d::NLPEvaluator, g, x)
    _reverse_mode(d, x)
    for i in 1:length(d.constraints)
        g[i] = d.constraints[i].expr.forward_storage[1]
    end
    return
end

function MOI.jacobian_structure(d::NLPEvaluator)
    J = Tuple{Int64,Int64}[]
    for (row, constraint) in enumerate(d.constraints)
        for col in constraint.grad_sparsity
            push!(J, (row, col))
        end
    end
    return J
end

function MOI.constraint_gradient_structure(d::NLPEvaluator, i)
    return copy(d.constraints[i].grad_sparsity)
end

function MOI.eval_constraint_gradient(d::NLPEvaluator, ∇g, x, i)
    _reverse_mode(d, x)
    for k in d.constraints[i].grad_sparsity
        d.jac_storage[k] = 0.0
    end
    _extract_reverse_pass(d.jac_storage, d, d.constraints[i])
    for (j, k) in enumerate(d.constraints[i].grad_sparsity)
        ∇g[j] = d.jac_storage[k]
    end
    return
end

function MOI.eval_constraint_jacobian(d::NLPEvaluator, J, x)
    _reverse_mode(d, x)
    fill!(J, 0.0)
    offset = 0
    for ex in d.constraints
        for i in ex.grad_sparsity
            d.jac_storage[i] = 0.0
        end
        _extract_reverse_pass(d.jac_storage, d, ex)
        for (k, idx) in enumerate(ex.grad_sparsity)
            J[offset+k] = d.jac_storage[idx]
        end
        offset += length(ex.grad_sparsity)
    end
    return
end

function MOI.eval_constraint_jacobian_product(d::NLPEvaluator, y, x, w)
    _reverse_mode(d, x)
    fill!(y, 0.0)
    for (row, expr) in enumerate(d.constraints)
        for col in expr.grad_sparsity
            d.jac_storage[col] = 0.0
        end
        _extract_reverse_pass(d.jac_storage, d, expr)
        for col in expr.grad_sparsity
            y[row] += d.jac_storage[col] * w[col]
        end
    end
    return
end

function MOI.eval_constraint_jacobian_transpose_product(
    d::NLPEvaluator,
    y::AbstractVector{Float64},
    x::AbstractVector{Float64},
    w::AbstractVector{Float64},
)
    _reverse_mode(d, x)
    fill!(y, 0.0)
    for (row, expr) in enumerate(d.constraints)
        for col in expr.grad_sparsity
            d.jac_storage[col] = 0.0
        end
        _extract_reverse_pass(d.jac_storage, d, expr)
        for col in expr.grad_sparsity
            y[col] += d.jac_storage[col] * w[row]
        end
    end
    return
end

function MOI.hessian_objective_structure(d::NLPEvaluator)
    @assert d.want_hess
    ret = Tuple{Int64,Int64}[]
    obj = d.objective
    if obj !== nothing
        for (i, j) in zip(obj.hess_I, obj.hess_J)
            push!(ret, (i, j))
        end
    end
    return ret
end

function MOI.hessian_constraint_structure(d::NLPEvaluator, c::Integer)
    @assert d.want_hess
    con = d.constraints[c]
    return Tuple{Int64,Int64}[(i, j) for (i, j) in zip(con.hess_I, con.hess_J)]
end

function MOI.hessian_lagrangian_structure(d::NLPEvaluator)
    @assert d.want_hess
    return d.hessian_sparsity
end

function MOI.eval_hessian_objective(d::NLPEvaluator, H, x)
    @assert d.want_hess
    _reverse_mode(d, x)
    fill!(d.input_ϵ, 0.0)
    if d.objective !== nothing
        _eval_hessian(d, something(d.objective), H, 1.0, 0)
    end
    return
end

function MOI.eval_hessian_constraint(d::NLPEvaluator, H, x, i)
    @assert d.want_hess
    _reverse_mode(d, x)
    fill!(d.input_ϵ, 0.0)
    _eval_hessian(d, d.constraints[i], H, 1.0, 0)
    return
end

function MOI.eval_hessian_lagrangian(d::NLPEvaluator, H, x, σ, μ)
    @assert d.want_hess
    _reverse_mode(d, x)
    fill!(d.input_ϵ, 0.0)
    offset = 0
    if d.objective !== nothing
        offset += _eval_hessian(d, something(d.objective), H, σ, offset)::Int
    end
    for (i, ex) in enumerate(d.constraints)
        offset += _eval_hessian(d, ex, H, μ[i], offset)::Int
    end
    return
end

function MOI.eval_hessian_lagrangian_product(d::NLPEvaluator, h, x, v, σ, μ)
    _reverse_mode(d, x)
    fill!(h, 0.0)
    T = ForwardDiff.Partials{1,Float64}
    input_ϵ = reinterpret(T, d.input_ϵ)
    output_ϵ = reinterpret(T, d.output_ϵ)
    for i in 1:length(x)
        input_ϵ[i] = ForwardDiff.Partials((v[i],))
    end
    # forward evaluate all subexpressions once
    subexpr_forward_values_ϵ = reinterpret(T, d.subexpression_forward_values_ϵ)
    for i in d.subexpression_order
        subexpr = d.subexpressions[i]
        subexpr_forward_values_ϵ[i] = _forward_eval_ϵ(d, subexpr, T)
    end
    # we only need to do one reverse pass through the subexpressions as well
    subexpr_reverse_values_ϵ = reinterpret(T, d.subexpression_reverse_values_ϵ)
    fill!(subexpr_reverse_values_ϵ, zero(T))
    fill!(d.subexpression_reverse_values, 0.0)
    fill!(d.storage_ϵ, 0.0)
    fill!(output_ϵ, zero(T))
    if d.objective !== nothing
        _forward_eval_ϵ(d, something(d.objective).expr, T)
        _reverse_eval_ϵ(
            output_ϵ,
            something(d.objective).expr,
            _reinterpret_unsafe(T, d.storage_ϵ),
            d.subexpression_reverse_values,
            subexpr_reverse_values_ϵ,
            σ,
            zero(T),
        )
    end
    for (i, con) in enumerate(d.constraints)
        _forward_eval_ϵ(d, con.expr, T)
        _reverse_eval_ϵ(
            output_ϵ,
            con.expr,
            reinterpret(T, d.storage_ϵ),
            d.subexpression_reverse_values,
            subexpr_reverse_values_ϵ,
            μ[i],
            zero(T),
        )
    end
    for i in length(d.subexpression_order):-1:1
        j = d.subexpression_order[i]
        subexpr = d.subexpressions[j]
        _reverse_eval_ϵ(
            output_ϵ,
            subexpr,
            reinterpret(T, d.storage_ϵ),
            d.subexpression_reverse_values,
            subexpr_reverse_values_ϵ,
            d.subexpression_reverse_values[j],
            subexpr_reverse_values_ϵ[j],
        )
    end
    for i in 1:length(x)
        h[i] += output_ϵ[i].values[1]
    end
    return
end
