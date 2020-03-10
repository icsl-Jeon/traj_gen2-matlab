classdef PolyTrajGen < TrajGen 
    properties (SetAccess = private)
        % Basic params 
        algorithm;  % mellinger or roy       
        
        % Polynomial 
        polyCoeffSet; % set of P = [p1 p2 ... pM] where pm = (N+1) x 1 vector 
        N; % polynomial order        
        M; % number of segment of polynomial     
        maxContiOrder; % maximum degree of continuity when joining two segments 
        
        % Optimization 
        nVar; % total number of variables         
        Qset; % set of quadratic objective 
        AeqSet; beqSet % set of eqaulity constraints 
        ASet; bSet;  % set of inequality constraints 
        NconstraintFixedPin; % number of eq constraints per segment. This checks the feasibility of optimization.                  
    end

    %% 1. Public method
    methods % public methods 
        function obj = PolyTrajGen(knots,order,algo,dim,maxContiOrder)
            %  PolyTrajGen(knots,order,algo,dim)
            % Intialize the functor to generate trajectory  
            obj.N = order; obj.Ts = knots; obj.algorithm = algo; 
            obj.dim = dim; obj.M = length(knots)-1; 
            obj.maxContiOrder = maxContiOrder;      
            obj.nVar = (obj.N+1) * (obj.M);
            % Optimization 
            obj.AeqSet = cell(dim);
            obj.beqSet = cell(dim);
            obj.ASet = cell(dim);
            obj.bSet = cell(dim);            
            obj.Qset = cell(dim);
            obj.isSolved = false; 
            
            for dd = 1:obj.dim
                obj.NconstraintFixedPin{dd} = zeros(1,obj.M);            
            end            
        end
        
        function setDerivativeObj(obj,weight_mask)
            % setDerivativeObj(obj,weight_mask)
            % Set the derivative objective functions. weight_mask ith element = penalty weight for intgeral of i th-derivative squared           
            if length(weight_mask) > obj.N
                warning('Order of derivative objective > order of poly. Higher terms will be ignored. ');
                weight_mask = weight_mask(1:obj.N);               
            end
            
            % Build quadratic terms to penalize d th order derivatives weighted by weight_mask            
            Q = zeros(obj.nVar);
            for d = 1:length(weight_mask)
                for m = 1:obj.M
                    dT = obj.Ts(m+1) - obj.Ts(m);  
                    Qm{m} = obj.IntDerSquard(d)/dT^(2*d-1);
                end
                Qd = blkdiag(Qm{:}); Q = Q + weight_mask(d)*Qd;               
            end
            % For all dimensions, we collect Q term.  
            for dd = 1:obj.dim
                obj.Qset{dd}  = Q;
            end            
        end
        
        function addPin(obj,pin)            
            % addPin(obj,pin)    
            % Impose a constraint to the dth derivative at time t to X as
            % an equality (fix pin) or inequality (loose pin). In case of
            % fix pin, imposing time should be knots of this polynomial.
            % pin = struct('t',,'d',,'X',)
            % X = Xval or X = [Xl Xu] where Xl or Xu is D x 1 vector
            
            t = pin.t; d = pin.d; X = pin.X; % the t is global time 
            assert (size(X,1) == obj.dim,'dim of pin val != dim of this TrajGen\n');
            [m,tau] = obj.findSegInteval(t); 
            addPin@TrajGen(obj,pin); % call the common function of addPin 
            
            % Prepare insertion
            idxStart = (m-1)*(obj.N+1) + 1; idxEnd = m*(obj.N+1);
            dTm = obj.Ts(m+1) - obj.Ts(m);
            % Insert the pin constraint 
            if size(X,2) == 2 % inequality (loose pin)
                for dd = 1:obj.dim % X,Y,Z or Yaw...
                    a = zeros(2,obj.nVar); b = zeros(2,1);                    
                    a(:,idxStart:idxEnd)  = [obj.tVec(tau,d)'/dTm^d; -obj.tVec(tau,d)'/dTm^d;]; b(:) = [X(dd,2)  -X(dd,1)];
                    obj.ASet{dd} = [obj.ASet{dd} ; a]; obj.bSet{dd} = [obj.bSet{dd} ; b];
                end            
            elseif size(X,2) == 1 % equality (fixed pin)
                assert (t == obj.Ts(m) || t == obj.Ts(m+1),'Fix pin should be imposed only knots\n');
                for dd = 1:obj.dim % X,Y,Z or Yaw...
                    aeq = zeros(1,obj.nVar); 
                    aeq(:,idxStart:idxEnd)  = obj.tVec(tau,d)'/dTm^d; beq = X(dd);
                    obj.AeqSet{dd} = [obj.AeqSet{dd} ;aeq]; obj.beqSet{dd} = [obj.beqSet{dd}; beq];
                    % This segment added equality constraints                     
                    obj.NconstraintFixedPin{dd}(m) = obj.NconstraintFixedPin{dd}(m) + 1; 
                    if obj.NconstraintFixedPin{dd}(m) >= obj.N+1
                        warning('No admissible constraints left on the segment\n');
                    end
                end            
            else
                disp('Invalid pin. Either X or [Xl Xu] to be expected, where X is col vec.\n');
                return 
            end            
        end             

        function solve(obj)           
            obj.isSolved = true;
            for dd = 1:obj.dim % per element 
                % First, we complete the continuity constraint 
                dof = obj.N+1 - obj.NconstraintFixedPin{dd}; % total dof 
                contiDof = min(dof,obj.maxContiOrder); % dof of segment m to be used for continuity 

                for m = 1:obj.M-1                    
                    if contiDof(m) ~= obj.maxContiOrder
                        warnStr = sprintf('Connecting segment (%d,%d) : lacks %d dof  for imposed %d th continuity',...
                                                m,m+1,obj.maxContiOrder - contiDof(m),obj.maxContiOrder);
                        warning(warnStr);
                    end                    
                    obj.addContinuity(m,contiDof(m))
                end
                
                % Then, solve the optimization 
                fprintf('solving %d th dimension..\n', dd)
                [Phat,~,flag] = quadprog(obj.Qset{dd},[],obj.ASet{dd},obj.bSet{dd},obj.AeqSet{dd},obj.beqSet{dd});
                obj.isSolved = obj.isSolved && (flag == 1); 
                if (flag == 1)
                    P = obj.scaleMatBigInv*Phat;
                    obj.polyCoeffSet{dd} = reshape(P,obj.N+1,[]);
                    fprintf('Success!\n');                    
                else
                    fprintf('Failure..\n');                    
                end
                
            end                        
            fprintf('Done!\n');
        end
        
        function val = eval(obj,t,d)
            % val = eval(obj,t,d) 
            % Evaluate d th order derivative of the piecewise polynomial at time t or at time sequence t. Extrapolation is turned on. 
            val = zeros(obj.dim,length(t)); 
            for dd = 1:obj.dim
                for idx = 1:length(t)
                    ti = t(idx);
                    [m,~]=obj.findSegInteval(ti);                    
                    dTm = obj.Ts(m+1) - obj.Ts(m); 
                    val(dd,idx) = obj.tVec((ti - obj.Ts(m)),d)'*obj.polyCoeffSet{dd}(:,m); 
                end
            end
        end        
    end % public method
    %% 2. Priavte method 
    methods (Access = public) % to be private 
        function val = B(obj,n,d)
            % Returns the nth order ceoffs (n=0...N) of time vector of dth
            % derivative.
            if d == 0
                val = 1;
            else
                accumProd = cumprod(n:-1:n-(d-1));
                val = (n>=d) * accumProd(end);
            end
        end
        function vec = tVec(obj,t,d)
            % time vector evaluated at time t with d th order derivative.
            vec = zeros(obj.N+1,1);
            for i = d+1:obj.N+1
                vec(i) = obj.B(i-1,d)*t^(i-1-d);
            end
        end
        
        function mat = scaleMat(obj,delT)
            mat = zeros(obj.N+1);
            for i = 1:obj.N+1
                mat(i,i) = delT^(i-1);
            end
        end
        
        function mat = scaleMatBig(obj)
            % scaling matrix with all knots. Used to remap phat to p 
            matSet = {};
            for m = 1:obj.M
                matSet{m} = obj.scaleMat(obj.Ts(m+1)-obj.Ts(m));
            end
            mat = blkdiag(matSet{:});
        end
        
        function mat = scaleMatBigInv(obj)
            % scaling matrix with all knots. Used to remap phat to p 
            matSet = {};
            for m = 1:obj.M
                matSet{m} = obj.scaleMat(1/(obj.Ts(m+1)-obj.Ts(m)));
            end
            mat = blkdiag(matSet{:});
        end
        
        function mat = IntDerSquard(obj,d)
            % integral (0 to 1) of squard d th derivative 
            if d > obj.N
                warning('Order of derivative > poly order \n')                
            end
            mat = zeros(obj.N+1);
            for i = 1:obj.N+1
                for j = 1:obj.N+1
                    if (i+j-2*d -1) > 0 
                        mat(i,j) = obj.B(i-1,d) *obj.B(j-1,d) / (i+j-2*d-1);                
                    end
                end
            end            
        end
        
        function [m,tau] = findSegInteval(obj,t)          
            % [m,tau] = findSegInteval(obj,t) 
            % returns the segment index + nomalized time, which contains time t              
            m = max(find(t >= obj.Ts));            
            if isempty(m)
                warning('Eval of t : leq T0. eval target = 1st segment')
                m = 1;
            elseif m >= obj.M+1
                if t ~= obj.Ts(end)
                    warning('Eval of t : geq TM. eval target = last segment')                
                end
                m = obj.M;
            else
                
            end                                    
            tau = (t - obj.Ts(m)) / (obj.Ts(m+1) - obj.Ts(m));                            
        end       

        function addContinuity(obj,m,dmax)
            % addContinuity(obj,m,dmax)
            % add continuity C^(dmax) th continuity to seg m with seg (m+1)
            idxStart = (m-1)*(obj.N+1) + 1; idxEnd = (m+1)*(obj.N+1);    
            for dd = 1:obj.dim
                for d = 0:dmax
                    dTm1 = obj.Ts(m+1) - obj.Ts(m);
                    dTm2 = obj.Ts(m+2) - obj.Ts(m+1);                    
                    aeq = zeros(1,obj.nVar);
                    aeq(idxStart : idxEnd) = [obj.tVec(1,d)'/dTm1^(d) -obj.tVec(0,d)'/dTm2^(d)]; 
                    obj.AeqSet{dd} = [obj.AeqSet{dd}; aeq]; obj.beqSet{dd} = [obj.beqSet{dd} ; 0];
                end
            end
        end
    end
    
    
    
end