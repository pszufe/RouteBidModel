
@with_kw struct ModelParams
    CoF =  0.15e-3;
    initialAgents=500
    maxAgents=500
    timeMax=Inf
    maxIter=10

    unused_lanes = [
        [1214, 532], #east bridge lane
        [1044, 1045], #east bridge lane
        [635, 747]   #west bridge lane
    ]
    nodes_to_remove = [e[1] for e in unused_lanes]

    east_bridge_lane = [445, 446] #OK
    west_bridge_lane = [965, 112] #OK
    bridgenodes = [east_bridge_lane[1], west_bridge_lane[1]]
end

@with_kw struct Road
    rlen::Float64
    agents=Set{Int}()
    bNode::Int
    fNode::Int
    vMax::Float64
    ttime=rlen/vMax
end

@with_kw mutable struct Intersection
    nodeID::Int
    osmNodeID::Int
    posX::Float64
    posY::Float64
    inRoads= Vector{Road}();
    outRoads= Vector{Road}();
    spawnPoint=false
    destPoint=false
    lat=0.0
    lon=0.0
end


@with_kw mutable struct Agent
    id::Int
    startNode::Intersection
    destNode::Intersection
    routes=[Vector{Int}() for i in 1:2]
    travelledRoute=rand(1:2)
    timeEstim=0.0
    deployTime=0.0
    arrivalTime::Union{Nothing,Float64}=nothing
    valueOfTime=maximum([24.52/60.0/60.0+randn()*3.0/60.0/60.0, 0.0])
    routesCost=[0.0, 0.0]
    routesDist=[0.0, 0.0]
    routesTime=[0.0, 0.0]

end


@with_kw mutable struct Network
    roads=Vector{Road}()
    intersections=Vector{Intersection}()
    spawns=Vector{Int}()  #points where agents can spawn
    dests=Vector{Int}() #points that can be targets for agents
    numRoads = 0
    agents=Dict{Int,Agent}()
    graph::SimpleWeightedDiGraph
    mapData::MapData
    agentCntr=0  #number of current agents
    agentIDmax=0 #maximum ID of agents on map
end



@with_kw mutable struct Simulation
    p = ModelParams()
    network::Network
    timeStep=1.0
    timeElapsed=0.0
    iter = 0  #step t

    agentsFinished=Vector{Agent}()
end

function init_network!(n::Network, coords::Vector{Tuple{Float64,Float64,Float64}})
    n.intersections = Vector{Intersection}(undef,n.graph.weights.m)
    for i in 1:n.graph.weights.m
        n.intersections[i] = Intersection(nodeID=i, osmNodeID=n.mapData.n[i], posX=coords[i][1], posY=coords[i][2])
        n.intersections[i].lat = LLA(ENU(n.intersections[i].posX, n.intersections[i].posY, 0), n.mapData.bounds).lat
        n.intersections[i].lon = LLA(ENU(n.intersections[i].posX, n.intersections[i].posY, 0), n.mapData.bounds).lon
    end

    for i in 1:n.graph.weights.m
        for j in 1:n.graph.weights.n
            if n.graph.weights[i, j] != 0
                n.numRoads += 1
                #println("$(n.numRoads): $(i) -> $(j) = $(n.graph.weights[i,j])")
            end
        end
    end
    n.roads = Vector{Road}(undef, n.numRoads)
    r = 0
    vels = OpenStreetMapX.get_velocities(n.mapData)
    for i in 1:n.graph.weights.m
        for j in 1:n.graph.weights.n
            if n.graph.weights[i, j] != 0
                r += 1
                n.roads[r] = Road(rlen=n.graph.weights[i, j], bNode=i, fNode=j,
                    vMax=(i <= vels.m && j <= vels.n) && vels[i,j] > 0 ? vels[i, j] : 40 / 3.6)
                push!(n.intersections[i].outRoads, n.roads[r])
                push!(n.intersections[j].inRoads, n.roads[r])
            end
        end
    end
    @info "Network has been successfully initialized."
end


function convert_to_network(m::MapData)::Network
    g =  SimpleWeightedDiGraph()
    add_vertices!(g, length(m.n))
    for edge in m.e
        #    dist = DistanceENU(m.nodes[edge[1]], m.nodes[edge[2]])
        dist = m.w[m.v[edge[1]], m.v[edge[2]]]
        add_edge!(g, m.v[edge[1]], m.v[edge[2]], dist)
        add_edge!(g, m.v[edge[2]], m.v[edge[1]], dist)
    end
    net =  Network(graph=g, mapData=m)
    coords = [m.nodes[m.n[i]] for i in 1:length(m.n)]
    init_network!(net, [(i.east, i.north, i.up) for i in coords])
    return net
end

Network(map::MapData) = return  convert_to_network(map)


function set_spawn_dest!(n::Network, spawns::Vector{Int}, dests::Vector{Int})
    empty!(n.spawns)
    for i in spawns
        n.intersections[i].spawnPoint = true
        push!(n.spawns, n.intersections[i].nodeID)
    end

    empty!(n.dests)
    for i in dests
        n.intersections[i].destPoint = true
        push!(n.dests, n.intersections[i].nodeID)
    end
end



function get_road_by_nodes(n::Network, first::Int, second::Int)::Union{Road,Nothing} #Take two nodes, get road between them
    if first > length(n.intersections) || second > length(n.intersections) #If ID of either nodes not in intersections range give error
        error("Node of of boundries")
    else #Otherwise
        for r in n.roads #For each road
            if r.bNode == first && r.fNode == second #If beggining node equals first and...etc.
                return r #Return the road
            end
        end
    end
    println("Cannot find road: [$first, $second]")
    return nothing
end


function getintersect(n::Network, id::Int)::Intersection #Takes the network and node ID of the node Intersection it's currently on
    for i in n.intersections
        if i.nodeID == id
            return i #Return the information for the intersection they're on
        end
    end
    return nothing
end


function get_agent_by_id(n::Network, id::Int)::Union{Agent,Nothing}
    get(n.agents, id, nothing)
end


function get_agent_by_id(agents::AbstractVector{Agent}, id::Int)::Union{Agent,Nothing}
    for a in agents
        a.id == id && return a
    end
    return nothing
end


function get_intersection_coords(n::Network)::DataFrame
    df = DataFrame(first_X = Float64[], first_Y = Float64[], second_X = Float64[], second_Y = Float64[])
    for p in GetIntersectionCoords(n)
        push!(df, Dict( :first_X => p[1][1], :first_Y => p[1][2], :second_X => p[2][1], :second_Y => p[2][2]))
    end
    return df
end



function get_nodes_in_radius(n::Network, pt::Tuple{Real,Real}, r::Real)::Vector{Int}
    v = Vector{Int}()
    for i in 1:length(n.intersections)
        if EuclideanNorm(pt, (n.intersections[i].posX, n.intersections[i].posY)) <= r
            push!(v, i)
        end
    end
    return v
end


function get_nodes_outside_radius(n::Network, pt::Tuple{Real,Real}, r::Real)::Vector{Int}
    v = Vector{Int}()
    for i in 1:length(n.intersections)
        if EuclideanNorm(pt, (n.intersections[i].posX, n.intersections[i].posY)) > r
            push!(v, i)
        end
    end
    return v
end



function get_nodes_between(n::Network, pt::Tuple{Real,Real}, r::Real, R::Real)::Vector{Int}
    v = Vector{Int}()
    for i in 1:length(n.intersections)
        if (EuclideanNorm(pt, (n.intersections[i].posX, n.intersections[i].posY)) > r) && (EuclideanNorm(pt, (n.intersections[i].posX, n.intersections[i].posY)) < R)
            push!(v, i)
        end
    end
    return v
end


function can_fit_at_road(a::Agent, r::Road)::Bool
    if  r.bNode in s0[1:end-1] || r.bNode in s1[1:end-1]
        return length(r.agents) < r.capacity #Check theres room on road for agent
    else
        return true
    end
end

function recalculate_road!(s::Simulation, r::Road) #Set Velocity function
    #velocity calculated only on active lanes of bridges
    if  r.bNode in s.p.bridgnodes
        r.curVelocity = min(lin_k_f_model(length(r.agents), r.capacity, r.vMax, r.vMin), r.vMax)
    elseif r.bNode in s.p.nodes_to_remove
        r.curVelocity = 0
    else
        r.curVelocity = r.vMax
    end
    #Set the current velocity all cars are going on this road based on length, number of agents on the road (congestion), etc.
    r.ttime = r.length / r.curVelocity
end

function get_route_distance(n::Network, r::Vector{Int})::Real
    len = 0.
    for i in 1:(length(r)-1)
        len += get_road_by_nodes(n, r[i], r[i + 1]).length
    end
    return len
end


function spawn_agents!(s::Simulation, dt::Real, λ = 20.0)
    if s.maxAgents == s.network.agentCntr
        return
    end
    k = minimum([λ,  s.maxAgents - s.network.agentCntr])      # minimum([maximum([rand(Distributions.Poisson(λ * dt)), 0]), s.maxAgents - s.network.agentCntr])
    for i in 1:k
        spawn_agent_random!(s.network, s.timeElapsed)
        set_weights!(s.network.agents[end], s);
    end
end

function spawn_num_agents!(s::Simulation, num::Int)
    maps = [deepcopy(s.network.mapData), deepcopy(s.network.mapData)]
    maps[1].w[s.p.east_bridge_lane...] = Inf
    maps[2].w[s.p.west_bridge_lane...] = Inf
    num = min(num, s.p.maxAgents - s.network.agentCntr)
    for i in 1:num
        a = spawn_agent_random!(s.network, s.timeElapsed)
        s.network.agentIDmax += 1
        s.network.agentCntr += 1
        s.network.agents[s.network.agentIDmax]=a
        for i in 1:2
            a.routes[i], a.routesDist[i], a.routesTime[i] =
                OpenStreetMapX.fastest_route(maps[i],a.startNode.osmNodeID, a.destNode.osmNodeID)
        end
    end

end


function spawn_agent_random!(n::Network, time::Float64 = 0.0)
    local start::Int64
    local dest::Int64
    create_agent = false

    while create_agent == false
        start = rand(n.spawns)
        dest = rand(n.dests)
        create_agent = is_route_possible(n,start,dest)
    end
    return Agent(id=n.agentIDmax, startNode=n.intersections[start],destNode=n.intersections[dest], deployTime=time) #Randomly spawn an agent within the outer region
end


function remove_from_road!(r::Road, a::Agent)
    pop!(r.agents,a.id, nothing )
end

function destroy_agent(a::Agent, n::Network)
    pop!(n.agents, a.id) #Deletes the agent from the network
    n.agentCntr -= 1 #Global current agents in the network is subtracted by 1
end

function set_weights!(a::Agent, s::Simulation)
    for r in s.network.roads
        r.ttime = r.length / r.curVelocity
        a.reducedGraph.weights[r.bNode, r.fNode] =  r.ttime * a.valueOfTime + r.length * a.CoF
    end
end

function set_shortest_path_both_bridges!(a::Agent, nw::Network)::Real
    ### correct Disktra PSZ pszufe

    # TODO path westerm + path eastern
    empty!(a.route1)
    nxtNode = a.atNode != nothing ? a.atNode.nodeID : a.atRoad.fNode

    s_star = LightGraphs.dijkstra_shortest_paths(a.reducedGraph, a.destNode.nodeID) #Find the shortest path between the node currently at and destination node
    dist = s_star.dists[nxtNode]
    if dist != Inf
        nextNode = nxtNode
        path = s_star.parents
        while nextNode != 0
            nextNode = path[nextNode]
            push!(a.route1, nextNode)
        end
        pop!(a.route1)
        a.timeEstim = estimate_timeQuick(nw, a.route1)
        return a.route1Cost = dist
    else
        return Inf
    end
end


function runsim!(s::Simulation, runTime::Int = 0)
    #agents have been spawned in Simulation constructor
    return true
end

function lin_k_f_model(k::Int, k_max::Int, v_max::Real = 50.0 / 3.6, v_min::Real = 1.0 / 3.6)
    if k > k_max
        return v_min
    else
        return (v_max - v_min) * (1.0 - k / k_max) + v_min
    end
    #return  v < 0 || v == NaN ? throw(Exception("Velocity less than zero or not a number")) : v
end

function DistanceENU(p1::ENU, p2::ENU)
    return sqrt((p1.east - p2.east)^2 + (p1.north - p2.north)^2 + (p1.up - p2.up)^2)
end

function EuclideanNorm(p1::Tuple{Real,Real}, p2::Tuple{Real,Real})
    return sqrt((p1[1] - p2[1])^2 + (p1[2] - p2[2])^2)
end

function is_route_possible(n::Network, startNode::Int64, endNode::Int64)
    route = LightGraphs.dijkstra_shortest_paths(n.graph,endNode)
    dist = route.dists[startNode]
    if dist == Inf
        return false
    return true
    end
end

function calculate_route_cost(a::Agent, s::Simulation, route::Vector{Int})
    nw = s.network
    if length(route) < 2
        return 0.0
    end

    cost = 0.0
    for i in 2:length(route)
        r = get_road_by_nodes(nw, route[i - 1], route[i])
        r.ttime = r.length / r.curVelocity
        cost +=  r.ttime * a.valueOfTime + r.length * a.CoF
    end

    return cost
end

function savesim(sim::Simulation, filename::AbstractString)::Bool
    f = open(filename, "w")
    serialize(f, sim)
    close(f)
    @info "File successfully saved as $filename"
    return true
end

function savesim(sim::Simulation, path::AbstractString, filename::AbstractString)::Bool
    fname = joinpath(path,filename)
    f = open(fname, "w")
    serialize(f, sim)
    close(f)
    @info "File successfully saved as $fname"
    return true
end

function load_sim(filename::AbstractString)::Simulation
    f = open(filename, "r")
    sim = deserialize(f)
    close(f)

    return sim
end

function load_sim(path::AbstractString, filename::AbstractString)::Simulation
    fname = joinpath(path, filename)
    f = open(fname, "r")
    sim = deserialize(f)
    close(f)
    return sim
end
