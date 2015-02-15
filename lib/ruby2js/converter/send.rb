module Ruby2JS
  class Converter

    # (send nil :puts
    #   (int 1))

    # (attr nil :puts)

    # (sendw nil :puts
    #   (int 1))

    # Note: attr and sendw are only generated by filters.  Attr forces
    # interpretation as an attribute vs a function call with zero parameters.
    # Sendw forces parameters to be placed on separate lines.

    handle :send, :sendw, :attr do |receiver, method, *args|
      ast = @ast

      width = ((ast.type == :sendw && !@nl.empty?) ? 0 : @width)

      # strip '!' and '?' decorations
      method = method.to_s[0..-2] if method =~ /\w[!?]$/

      # three ways to define anonymous functions
      if method == :new and receiver and receiver.children == [nil, :Proc]
        return parse args.first
      elsif not receiver and [:lambda, :proc].include? method
        return parse args.first
      end

      # call anonymous function
      if [:call, :[]].include? method and receiver and receiver.type == :block 
        t2,m2,*args2 = receiver.children.first.children
        if not t2 and [:lambda, :proc].include? m2 and args2.length == 0
          receiver = (@state == :statement ? group(receiver) : parse(receiver))
          return parse s(:send, nil, receiver, *args)
        end
      end

      op_index = operator_index method
      if op_index != -1
        target = args.first 
      end

      # resolve anonymous receivers against rbstack
      receiver ||= @rbstack.map {|rb| rb[method]}.compact.last

      if receiver
        group_receiver = receiver.type == :send &&
          op_index < operator_index( receiver.children[1] ) if receiver
        group_receiver ||= [:begin, :dstr, :dsym].include? receiver.type
        group_receiver = false if receiver.children[1] == :[]
      end

      if target
        group_target = target.type == :send && 
          op_index < operator_index( target.children[1] )
        group_target ||= (target.type == :begin)
      end

      if method == :!
        parse s(:not, receiver)

      elsif method == :[]
        "#{ parse receiver }[#{ args.map {|arg| parse arg}.join(', ') }]"

      elsif method == :[]=
        "#{ parse receiver }[#{ args[0..-2].map {|arg| parse arg}.join(', ') }] = #{ parse args[-1] }"

      elsif [:-@, :+@, :~].include? method
        "#{ method.to_s[0] }#{ parse receiver }"

      elsif method == :=~
        "#{ parse args.first }.test(#{ parse receiver })"

      elsif method == :!~
        "!#{ parse args.first }.test(#{ parse receiver })"

      elsif method == :<< and args.length == 1 and @state == :statement
        "#{ parse receiver }.push(#{ parse args.first })"

      elsif method == :<=>
        raise NotImplementedError, "use of <=>"

      elsif OPERATORS.flatten.include?(method) and not LOGICAL.include?(method)
        "#{ group_receiver ? group(receiver) : parse(receiver) } #{ method } #{ group_target ? group(target) : parse(target) }"  

      elsif method =~ /=$/
        "#{ parse receiver }#{ '.' if receiver }#{ method.to_s.sub(/=$/, ' =') } #{ parse args.first }"

      elsif method == :new
        if receiver
          # map Ruby's "Regexp" to JavaScript's "Regexp"
          if receiver == s(:const, nil, :Regexp)
            receiver = s(:const, nil, :RegExp)
          end

          # allow a RegExp to be constructed from another RegExp
          if receiver == s(:const, nil, :RegExp)
            if args.first.type == :regexp
              opts = ''
              if args.first.children.last.children.length > 0
                opts = args.first.children.last.children.join
              end

              if args.length > 1
                opts += args.last.children.last
              end

              return parse s(:regexp, *args.first.children[0...-1],
                s(:regopt, *opts.split('').map(&:to_sym)))
            elsif args.first.type == :str
              if args.length == 2 and args[1].type == :str
                opts = args[1].children[0]
              else
                opts = ''
              end
              return parse s(:regexp, args.first,
                s(:regopt, *opts.each_char.map {|c| c}))
            end
          end

          args = args.map {|a| parse a}.join(', ')

          if ast.is_method?
            "new #{ parse receiver }(#{ args })"
          else
            "new #{ parse receiver }"
          end
        elsif args.length == 1 and args.first.type == :send
          # accommodation for JavaScript like new syntax w/argument list
          parse s(:send, s(:const, nil, args.first.children[1]), :new,
            *args.first.children[2..-1]), @state
        elsif args.length == 1 and args.first.type == :const
          # accommodation for JavaScript like new syntax w/o argument list
          parse s(:attr, args.first, :new), @state
        else
          raise NotImplementedError, "use of JavaScript keyword new"
        end

      elsif method == :raise and receiver == nil
        if args.length == 1
          "throw #{ parse args.first }"
        else
          "throw new #{ parse args.first }(#{ parse args[1] })"
        end

      elsif method == :typeof and receiver == nil
        "typeof #{ parse args.first }"

      else
        if not ast.is_method?
          if receiver
             call = (group_receiver ? group(receiver) : parse(receiver))
            "#{ call }.#{ method }"
          else
            parse s(:lvasgn, method), @state
          end
        elsif args.length > 0 and args.any? {|arg| arg.type == :splat}
          parse s(:send, s(:attr, receiver, method), :apply, 
            (receiver || s(:nil)), s(:array, *args))
        else
          call = (group_receiver ? group(receiver) : parse(receiver))
          call = "#{ call }#{ '.' if receiver && method}#{ method }"
          args = args.map {|a| parse a}
          if args.any? {|arg| arg.to_s.include? "\n"}
            "#{ call }(#{ args.join(', ') })"
          elsif args.map {|arg| arg.length+2}.reduce(&:+).to_i < width-10
            "#{ call }(#{ args.join(', ') })"
          else
            "#{ call }(#@nl#{ args.join(",#@ws") }#@nl)"
          end
        end
      end
    end
  end
end
