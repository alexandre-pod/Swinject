//
//  Copyright © 2019 Swinject Contributors. All rights reserved.
//

import Foundation

/// The ``Container`` class represents a dependency injection container, which stores registrations of services
/// and retrieves registered services with dependencies injected.
///
/// **Example to register:**
///
///     let container = Container()
///     container.register(A.self) { _ in B() }
///     container.register(X.self) { r in Y(a: r.resolve(A.self)!) }
///
/// **Example to retrieve:**
///
///     let x = container.resolve(X.self)!
///
/// where `A` and `X` are protocols, `B` is a type conforming `A`, and `Y` is a type conforming `X`
/// and depending on `A`.
public final actor AsyncContainer {
    internal var services = [ServiceKey: AsyncServiceEntryProtocol]()
    private let parent: AsyncContainer? // Used by HierarchyObjectScope
    private var resolutionDepth = 0
    private let debugHelper: DebugHelper
    private let defaultObjectScope: ObjectScope
    internal var currentObjectGraph: GraphIdentifier?
    internal var graphInstancesInFlight = [AsyncServiceEntryProtocol]()
    internal var behaviors = [AsyncBehavior]()

    internal init(
        parent: AsyncContainer? = nil,
        debugHelper: DebugHelper,
        defaultObjectScope: ObjectScope = .graph
    ) {
        self.parent = parent
        self.debugHelper = debugHelper
        self.defaultObjectScope = defaultObjectScope
    }

    /// Instantiates a ``Container``
    ///
    /// - Parameters
    ///     - parent: The optional parent ``Container``.
    ///     - defaultObjectScope: Default object scope (graph if no scope is injected)
    ///     - behaviors: List of behaviors to be added to the container
    ///     - registeringClosure: The closure registering services to the new container instance.
    ///
    /// - Remark: Compile time may be long if you pass a long closure to this initializer.
    ///           Use `init()` or `init(parent:)` instead.
    public init(
        parent: AsyncContainer? = nil,
        defaultObjectScope: ObjectScope = .graph,
        behaviors: [AsyncBehavior] = [],
        registeringClosure: (AsyncContainer) -> Void = { _ in }
    ) async {
        self.init(parent: parent, debugHelper: LoggingDebugHelper(), defaultObjectScope: defaultObjectScope)
        behaviors.forEach(addBehavior)
        registeringClosure(self)
    }

    /// Removes all registrations in the container.
    public func removeAll() {
        services.removeAll()
    }

    /// Discards instances for services registered in the given `ObjectsScopeProtocol`.
    ///
    /// **Example usage:**
    ///     container.resetObjectScope(ObjectScope.container)
    ///
    /// - Parameters:
    ///     - objectScope: All instances registered in given `ObjectsScopeProtocol` will be discarded.
    public func resetObjectScope(_ objectScope: ObjectScopeProtocol) async {
        services.values
            .filter { $0.objectScope === objectScope }
            .forEach { $0.storage.instance = nil }
        await parent?.resetObjectScope(objectScope)
    }

    /// Discards instances for services registered in the given `ObjectsScope`. It performs the same operation
    /// as `resetObjectScope(_:ObjectScopeProtocol)`, but provides more convenient usage syntax.
    ///
    /// **Example usage:**
    ///     container.resetObjectScope(.container)
    ///
    /// - Parameters:
    ///     - objectScope: All instances registered in given `ObjectsScope` will be discarded.
    public func resetObjectScope(_ objectScope: ObjectScope) async {
        await resetObjectScope(objectScope as ObjectScopeProtocol)
    }

    /// Adds a registration for the specified service with the factory closure to specify how the service is
    /// resolved with dependencies.
    ///
    /// - Parameters:
    ///   - serviceType: The service type to register.
    ///   - name:        A registration name, which is used to differentiate from other registrations
    ///                  that have the same service and factory types.
    ///   - factory:     The closure to specify how the service type is resolved with the dependencies of the type.
    ///                  It is invoked when the ``Container`` needs to instantiate the instance.
    ///                  It takes a ``Resolver`` to inject dependencies to the instance,
    ///                  and returns the instance of the component type for the service.
    ///
    /// - Returns: A registered ``AsyncServiceEntry`` to configure more settings with method chaining.
    @discardableResult
    public func register<Service>(
        _ serviceType: Service.Type,
        name: String? = nil,
        factory: @escaping (Resolver) -> Service
    ) -> AsyncServiceEntry<Service> {
        return _register(serviceType, factory: factory, name: name)
    }

    /// This method is designed for the use to extend Swinject functionality.
    /// Do NOT use this method unless you intend to write an extension or plugin to Swinject framework.
    ///
    /// - Parameters:
    ///   - serviceType: The service type to register.
    ///   - factory:     The closure to specify how the service type is resolved with the dependencies of the type.
    ///                  It is invoked when the ``Container`` needs to instantiate the instance.
    ///                  It takes a ``Resolver`` to inject dependencies to the instance,
    ///                  and returns the instance of the component type for the service.
    ///   - name:        A registration name.
    ///   - option:      A service key option for an extension/plugin.
    ///
    /// - Returns: A registered ``AsyncServiceEntry`` to configure more settings with method chaining.
    @discardableResult
    // swiftlint:disable:next identifier_name
    public func _register<Service, Arguments>(
        _ serviceType: Service.Type,
        factory: @escaping (Arguments) async -> Any,
        name: String? = nil,
        option: ServiceKeyOption? = nil
    ) -> AsyncServiceEntry<Service> {
        let key = ServiceKey(serviceType: Service.self, argumentsType: Arguments.self, name: name, option: option)
        let entry = AsyncServiceEntry(
            serviceType: serviceType,
            argumentsType: Arguments.self,
            factory: factory,
            objectScope: defaultObjectScope
        )
        entry.container = self
        services[key] = entry

        behaviors.forEach { $0.container(self, didRegisterType: serviceType, toService: entry, withName: name) }

        return entry
    }

    /// Adds behavior to the container. `Behavior.container(_:didRegisterService:withName:)` will be invoked for
    /// each service registered to the `container` **after** the behavior has been added.
    ///
    /// - Parameters:
    ///     - behavior: Behavior to be added to the container
    public func addBehavior(_ behavior: AsyncBehavior) {
        behaviors.append(behavior)
    }

    /// Check if a `Service` of a given type and name has already been registered.
    ///
    /// - Parameters:
    ///   - serviceType: The service type to compare.
    ///   - name:        A registration name, which is used to differentiate from other registrations
    ///                  that have the same service and factory types.
    ///
    /// - Returns: A  `Bool`  which represents whether or not the `Service` has been registered.
    public func hasAnyRegistration<Service>(
        of serviceType: Service.Type,
        name: String? = nil
    ) async -> Bool {
        let hasRegistrationInSelf = services.contains { key, _ in
            key.serviceType == serviceType && key.name == name
        }
        if hasRegistrationInSelf { return true }
        return await parent?.hasAnyRegistration(of: serviceType, name: name) == true
    }

    /// Applies a given GraphIdentifier across resolves in the provided closure.
    /// - Parameters:
    ///   - identifier: Graph scope to use
    ///   - closure: Actions to execute within the Container
    /// - Returns: Any value you return (Void otherwise) within the function call.
    public func withObjectGraph<T>(_ identifier: GraphIdentifier, closure: (AsyncContainer) throws -> T) rethrows -> T {
        let graphIdentifier = currentObjectGraph
        defer { self.currentObjectGraph = graphIdentifier }
        self.currentObjectGraph = identifier
        return try closure(self)
    }

    /// Restores the object graph to match the given identifier.
    /// Not synchronized, use lock to edit safely.
    internal func restoreObjectGraph(_ identifier: GraphIdentifier) {
        currentObjectGraph = identifier
    }
}

// MARK: - _Resolver

extension AsyncContainer: _AsyncResolver {
    // swiftlint:disable:next identifier_name
    public func _resolve<Service, Arguments>(
        name: String?,
        option: ServiceKeyOption? = nil,
        invoker: @escaping ((Arguments) async -> Any) async -> Any
    ) async -> Service? {
        // No need to use weak self since the resolution will be executed before
        // this function exits.
        var resolvedInstance: Service?
        let key = ServiceKey(serviceType: Service.self, argumentsType: Arguments.self, name: name, option: option)

        if key == Self.graphIdentifierKey {
            return currentObjectGraph as? Service
        }

        if let entry = await getEntry(for: key) {
            resolvedInstance = await resolve(entry: entry, invoker: invoker)
        }

        if resolvedInstance == nil {
            resolvedInstance = await resolveAsWrapper(name: name, option: option, invoker: invoker)
        }

        if resolvedInstance == nil {
            await debugHelper.resolutionFailed(
                serviceType: Service.self,
                key: key,
                availableRegistrations: getRegistrations()
            )
        }

        return resolvedInstance
    }

    fileprivate func resolveAsWrapper<Wrapper, Arguments>(
        name: String?,
        option: ServiceKeyOption?,
        invoker: @escaping ((Arguments) async -> Any) async -> Any
    ) async -> Wrapper? {
        guard let wrapper = Wrapper.self as? AsyncInstanceWrapper.Type else { return nil }

        let key = ServiceKey(
            serviceType: wrapper.wrappedType, argumentsType: Arguments.self, name: name, option: option
        )

        if let entry = await getEntry(for: key) {
            let factory = { [weak self] (graphIdentifier: GraphIdentifier?) async -> Any? in
                guard let self else { return nil }
                let originGraph = await self.currentObjectGraph
                if let graphIdentifier = graphIdentifier {
                    await self.restoreObjectGraph(graphIdentifier)
                }

                let result = await self.resolve(entry: entry, invoker: invoker) as Any?
                if let originGraph {
                    await self.restoreObjectGraph(originGraph)
                }
                return result
            }
            return await wrapper.init(inContainer: self, withInstanceFactory: factory) as? Wrapper
        } else {
            return await wrapper.init(inContainer: self, withInstanceFactory: nil) as? Wrapper
        }
    }

    fileprivate func getRegistrations() async -> [ServiceKey: AsyncServiceEntryProtocol] {
        var registrations = await parent?.getRegistrations() ?? [:]
        services.forEach { key, value in registrations[key] = value }
        return registrations
    }

    fileprivate var maxResolutionDepth: Int { return 200 }

    fileprivate func incrementResolutionDepth() async {
        await parent?.incrementResolutionDepth()
        if resolutionDepth == 0, currentObjectGraph == nil {
            currentObjectGraph = GraphIdentifier()
        }
        guard resolutionDepth < maxResolutionDepth else {
            fatalError("Infinite recursive call for circular dependency has been detected. " +
                       "To avoid the infinite call, 'initCompleted' handler should be used to inject circular dependency.")
        }
        resolutionDepth += 1
    }

    fileprivate func decrementResolutionDepth() async {
        await parent?.decrementResolutionDepth()
        assert(resolutionDepth > 0, "The depth cannot be negative.")

        resolutionDepth -= 1
        if resolutionDepth == 0 { graphResolutionCompleted() }
    }

    fileprivate func graphResolutionCompleted() {
        graphInstancesInFlight.forEach { $0.storage.graphResolutionCompleted() }
        graphInstancesInFlight.removeAll(keepingCapacity: true)
        currentObjectGraph = nil
    }
}

// MARK: - Resolver

extension AsyncContainer: AsyncResolver {
    /// Retrieves the instance with the specified service type.
    ///
    /// - Parameter serviceType: The service type to resolve.
    ///
    /// - Returns: The resolved service type instance, or nil if no registration for the service type
    ///            is found in the ``Container``.
    public func resolve<Service>(_ serviceType: Service.Type) async -> Service? {
        return await resolve(serviceType, name: nil)
    }

    /// Retrieves the instance with the specified service type and registration name.
    ///
    /// - Parameters:
    ///   - serviceType: The service type to resolve.
    ///   - name:        The registration name.
    ///
    /// - Returns: The resolved service type instance, or nil if no registration for the service type and name
    ///            is found in the ``Container``.
    public func resolve<Service>(_: Service.Type, name: String?) async -> Service? {
        return await _resolve(name: name) { (factory: (AsyncResolver) async -> Any) in await factory(self) }
    }

    fileprivate func getEntry(for key: ServiceKey) async -> AsyncServiceEntryProtocol? {
        if let entry = services[key] {
            return entry
        } else {
            return await parent?.getEntry(for: key)
        }
    }

    fileprivate func resolve<Service, Factory>(
        entry: AsyncServiceEntryProtocol,
        invoker: @escaping (Factory) async -> Any
    ) async -> Service? {
        await self.incrementResolutionDepth()
        // TODO: Handle this defer - done
//        defer { self.decrementResolutionDepth() }

        guard let currentObjectGraph = self.currentObjectGraph else {
            fatalError("If accessing container from multiple threads, make sure to use a synchronized resolver.")
        }

        if let persistedInstance = self.persistedInstance(Service.self, from: entry, in: currentObjectGraph) {
            await self.decrementResolutionDepth()
            return persistedInstance
        }

        let resolvedInstance = await invoker(entry.factory as! Factory)
        if let persistedInstance = self.persistedInstance(Service.self, from: entry, in: currentObjectGraph) {
            await self.decrementResolutionDepth()
            // An instance for the key might be added by the factory invocation.
            return persistedInstance
        }
        entry.storage.setInstance(resolvedInstance as Any, inGraph: currentObjectGraph)
        graphInstancesInFlight.append(entry)

        if let completed = entry.initCompleted as? (AsyncResolver, Any) -> Void,
           let resolvedInstance = resolvedInstance as? Service {
            completed(self, resolvedInstance)
        }

        await self.decrementResolutionDepth()
        return resolvedInstance as? Service
    }

    private func persistedInstance<Service>(
        _: Service.Type, from entry: AsyncServiceEntryProtocol, in graph: GraphIdentifier
    ) -> Service? {
        if let instance = entry.storage.instance(inGraph: graph), let service = instance as? Service {
            return service
        } else {
            return nil
        }
    }
}

// MARK: CustomStringConvertible

// Error: Actor-isolated property 'description' cannot be used to satisfy nonisolated protocol requirement
//extension AsyncContainer: CustomStringConvertible {
//    public var description: String {
//        return "["
//        + services.map { "\n    { \($1.describeWithKey($0)) }" }.sorted().joined(separator: ",")
//        + "\n]"
//    }
//}

// MARK: Constants

private extension AsyncContainer {
    static let graphIdentifierKey = ServiceKey(serviceType: GraphIdentifier.self, argumentsType: AsyncResolver.self)
}
