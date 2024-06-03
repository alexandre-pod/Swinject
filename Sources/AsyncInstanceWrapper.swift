//
//  Copyright © 2019 Swinject Contributors. All rights reserved.
//

protocol AsyncInstanceWrapper {
    static var wrappedType: Any.Type { get }
    init?(inContainer container: AsyncContainer, withInstanceFactory factory: ((GraphIdentifier?) async -> Any?)?) async
}

/// Wrapper to enable delayed dependency instantiation.
/// `Lazy<Type>` does not need to be explicitly registered into the ``Container`` - resolution will work
/// as long as there is a registration for the `Type`.
public final class AsyncLazy<Service>: AsyncInstanceWrapper {
    static var wrappedType: Any.Type { return Service.self }

    private let factory: (GraphIdentifier?) async -> Any?
    private let graphIdentifier: GraphIdentifier?
    private weak var container: AsyncContainer?

    init?(inContainer container: AsyncContainer, withInstanceFactory factory: ((GraphIdentifier?) async -> Any?)?) async {
        guard let factory = factory else { return nil }
        self.factory = factory
        graphIdentifier = await container.currentObjectGraph
        self.container = container
    }

    private var _instance: Service?

    /// Getter for the wrapped object.
    /// It will be resolved from the ``Container`` when first accessed, all other calls will return the same instance.
    public var instance: Service {
        get async {
            if let instance = _instance {
                return instance
            } else {
                _instance = await makeInstance()
                return _instance!
            }
        }
    }

    private func makeInstance() async -> Service? {
        await factory(graphIdentifier) as? Service
    }
}

/// Wrapper to enable delayed dependency instantiation.
/// `Provider<Type>` does not need to be explicitly registered into the ``Container`` - resolution will work
/// as long as there is a registration for the `Type`.
public final class AsyncProvider<Service>: AsyncInstanceWrapper {
    static var wrappedType: Any.Type { return Service.self }

    private let factory: (GraphIdentifier?) async -> Any?

    init?(inContainer _: AsyncContainer, withInstanceFactory factory: ((GraphIdentifier?) async -> Any?)?) {
        guard let factory = factory else { return nil }
        self.factory = factory
    }

    /// Getter for the wrapped object.
    /// New instance will be resolved from the ``Container`` every time it is accessed.
    public var instance: Service {
        get async {
            return await factory(.none) as! Service
        }
    }
}

extension Optional: AsyncInstanceWrapper {
//    static var wrappedType: Any.Type { return Wrapped.self }

    init?(inContainer _: AsyncContainer, withInstanceFactory factory: ((GraphIdentifier?) async -> Any?)?) async {
        self = await factory?(.none) as? Wrapped
    }
}
