function roundtrip_nonlinear_expression(
    expr, variable_to_string, string_to_variable
)
    node_list = MOF.OrderedObject[]
    object = MOF.convert_expr_to_mof(expr, node_list, variable_to_string)
    @test MOF.convert_mof_to_expr(object, node_list, string_to_variable) == expr
end

# hs071
# min x1 * x4 * (x1 + x2 + x3) + x3
# st  x1 * x2 * x3 * x4 >= 25
#     x1^2 + x2^2 + x3^2 + x4^2 = 40
#     1 <= x1, x2, x3, x4 <= 5
struct ExprEvaluator <: MOI.AbstractNLPEvaluator
    objective::Expr
    constraints::Vector{Expr}
end
MOI.features_available(::ExprEvaluator) = [:ExprGraph]
MOI.initialize(::ExprEvaluator, features) = nothing
MOI.objective_expr(evaluator::ExprEvaluator) = evaluator.objective
MOI.constraint_expr(evaluator::ExprEvaluator, i::Int) = evaluator.constraints[i]

function HS071(x::Vector{MOI.VariableIndex})
    x1, x2, x3, x4 = x
    return MOI.NLPBlockData(
        MOI.NLPBoundsPair.([25, 40], [Inf, 40]),
        ExprEvaluator(
            :(x[$x1] * x[$x4] * (x[$x1] + x[$x2] + x[$x3]) + x[$x3]),
            [
                :(x[$x1] * x[$x2] * x[$x3] * x[$x4] >= 25),
                :(x[$x1]^2 + x[$x2]^2 + x[$x3]^2 + x[$x4]^2 == 40)
            ]
        ),
        true
    )
end

@testset "Nonlinear functions" begin
    @testset "HS071 via MOI" begin
        model = MOF.Model()
        x = MOI.add_variables(model, 4)
        for (index, variable) in enumerate(x)
            MOI.set(model, MOI.VariableName(), variable, "var_$(index)")
        end
        MOI.add_constraints(model, MOI.SingleVariable.(x),
                            Ref(MOI.Interval(1.0, 5.0)))
        MOI.set(model, MOI.NLPBlock(), HS071(x))
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.write_to_file(model, TEST_MOF_FILE)
        @test replace(read(TEST_MOF_FILE, String), '\r' => "") ==
            replace(read(joinpath(@__DIR__, "nlp.mof.json"), String), '\r' => "")
        MOF.validate(TEST_MOF_FILE)
    end
    @testset "Error handling" begin
        node_list = MOF.Object[]
        string_to_variable = Dict{String, MOI.VariableIndex}()
        variable_to_string = Dict{MOI.VariableIndex, String}()
        # Test unsupported function for Expr -> MOF.
        @test_throws Exception MOF.convert_expr_to_mof(
            :(not_supported_function(x)), node_list, variable_to_string)
        # Test unsupported function for MOF -> Expr.
        @test_throws Exception MOF.convert_mof_to_expr(
            MOF.OrderedObject("head"=>"not_supported_function", "value"=>1),
            node_list, string_to_variable)
        # Test n-ary function with no arguments.
        @test_throws Exception MOF.convert_expr_to_mof(
            :(min()), node_list, variable_to_string)
        # Test unary function with two arguments.
        @test_throws Exception MOF.convert_expr_to_mof(
            :(sin(x, y)), node_list, variable_to_string)
        # Test binary function with one arguments.
        @test_throws Exception MOF.convert_expr_to_mof(
            :(^(x)), node_list, variable_to_string)
        # An expression with something other than :call as the head.
        @test_throws Exception MOF.convert_expr_to_mof(
            :(a <= b <= c), node_list, variable_to_string)
        # Hit the default fallback with an un-interpolated complex number.
        @test_throws Exception MOF.convert_expr_to_mof(
            :(1 + 2im), node_list, variable_to_string)
        # Invalid number of variables.
        @test_throws Exception MOF.substitute_variables(
            :(x[1] * x[2]), [MOI.VariableIndex(1)])
        # Function-in-Set
        @test_throws Exception MOF.extract_function_and_set(
            :(foo in set))
        # Not a constraint.
        @test_throws Exception MOF.extract_function_and_set(:(x^2))
        # Two-sided constraints
        @test MOF.extract_function_and_set(:(1 <= x <= 2)) ==
            MOF.extract_function_and_set(:(2 >= x >= 1)) ==
            (:x, MOI.Interval(1, 2))
        # Less-than constraint.
        @test MOF.extract_function_and_set(:(x <= 2)) ==
            (:x, MOI.LessThan(2))
    end
    @testset "Roundtrip nonlinear expressions" begin
        x = MOI.VariableIndex(123)
        y = MOI.VariableIndex(456)
        z = MOI.VariableIndex(789)
        string_to_var = Dict{String, MOI.VariableIndex}("x"=>x, "y"=>y, "z"=>z)
        var_to_string = Dict{MOI.VariableIndex, String}(x=>"x", y=>"y", z=>"z")
        for expr in [2, 2.34, 2 + 3im, x, :(1 + $x), :($x - 1),
                     :($x + $y), :($x + $y - $z), :(2 * $x), :($x * $y),
                     :($x / 2), :(2 / $x), :($x / $y), :($x / $y / $z), :(2^$x),
                     :($x^2), :($x^$y), :($x^(2 * $y + 1)), :(sin($x)),
                     :(sin($x + $y)), :(2 * $x + sin($x)^2 + $y),
                     :(sin($(3im))^2 + cos($(3im))^2), :($(1 + 2im) * $x),
                     :(ceil($x)), :(floor($x)), :($x < $y), :($x <= $y),
                     :($x > $y), :($x >= $y), :($x == $y), :($x != $y),
                     # :($x && $y), :($x || $y),
                     :(ifelse($x > 0, 1, $y))]
            roundtrip_nonlinear_expression(expr, var_to_string, string_to_var)
        end
    end
    @testset "Reading and Writing" begin
        # Write to file.
        model = MOF.Model()
        (x, y) = MOI.add_variables(model, 2)
        MOI.set(model, MOI.VariableName(), x, "var_x")
        MOI.set(model, MOI.VariableName(), y, "y")
        con = MOI.add_constraint(model,
                 MOF.Nonlinear(:(2 * $x + sin($x)^2 - $y)),
                 MOI.EqualTo(1.0))
        MOI.set(model, MOI.ConstraintName(), con, "con")
        MOI.write_to_file(model, TEST_MOF_FILE)
        # Read the model back in.
        model2 = MOF.Model()
        MOI.read_from_file(model2, TEST_MOF_FILE)
        con2 = MOI.get(model2, MOI.ConstraintIndex, "con")
        foo2 = MOI.get(model2, MOI.ConstraintFunction(), con2)
        # Test that we recover the constraint.
        @test foo2.expr == :(2 * $x + sin($x)^2 - $y)
        @test MOI.get(model, MOI.ConstraintSet(), con) ==
                MOI.get(model2, MOI.ConstraintSet(), con2)
        MOF.validate(TEST_MOF_FILE)
    end
end
