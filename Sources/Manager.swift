// The MIT License (MIT)
//
// Copyright (c) 2017 Alexander Grebenyuk (github.com/kean).

import Foundation

/// Loads images into the given targets.
public final class Manager {
    public let loader: Loading
    public let cache: Caching?

    private let queue = DispatchQueue(label: "com.github.kean.Nuke.Manager")

    /// Initializes the `Manager` with the image loader and the memory cache.
    /// - parameter cache: `nil` by default. `Manager` reads from the memory
    /// cache but doesn't write anything into it.
    public init(loader: Loading, cache: Caching? = nil) {
        self.loader = loader
        self.cache = cache
    }
    
    /// Loads an image into the given target. Cancels previous outstanding request
    /// associated with the target.
    ///
    /// If the image is stored in the memory cache, the image is displayed
    /// immediately. The image is loaded using the `loader` object otherwise.
    ///
    /// `Manager` keeps a weak reference to the target. If the target deallocates
    /// the associated request automatically gets cancelled.
    public func loadImage(with request: Request, into target: Target) {
        loadImage(with: request, into: target) { [weak target] in
            target?.handle(response: $0, isFromMemoryCache: $1)
        }
    }
    
    public typealias Handler = (Result<Image>, _ isFromMemoryCache: Bool) -> Void
    
    /// Loads an image and calls the given `handler`. The method itself 
    /// **doesn't do** anything when the image is loaded - you have full
    /// control over how to display it, etc.
    ///
    /// The handler only gets called if the request is still associated with the
    /// `target` by the time it's completed. The handler gets called immediately
    /// if the image was stored in the memory cache.
    ///
    /// See `loadImage(with:into:)` method for more info.
    public func loadImage(with request: Request, into target: AnyObject, handler: @escaping Handler) {
        assert(Thread.isMainThread)
        
        // Cancel outstanding request
        cancelRequest(for: target)
        
        // Quick memory cache lookup
        if request.memoryCacheOptions.readAllowed, let image = cache?[request] {
            handler(.success(image), true)
            return
        }
        
        // Start the request
        let cts = CancellationTokenSource(lock: CancellationTokenSource.lock)
        let context = Context(cts)
        Manager.setContext(context, for: target)
        
        loadImage(with: request, token: cts.token) { [weak self, weak context, weak target] result in
            if request.memoryCacheOptions.writeAllowed, let image = result.value {
                self?.cache?[request] = image
            }
            guard let context = context, let target = target else { return }
            guard Manager.getContext(for: target) === context else { return }
            handler(result, false)
            context.cts = nil // avoid redundant cancellations on deinit
        }
    }
    
    private func loadImage(with request: Request, token: CancellationToken, completion: @escaping (Result<Image>) -> Void) {
        queue.async {
            guard !token.isCancelling else { return } // fast preflight check
            self.loader.loadImage(with: request, token: token) { result in
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
    
    /// Cancels an outstanding request associated with the target.
    public func cancelRequest(for target: AnyObject) {
        assert(Thread.isMainThread)
        Manager.getContext(for: target)?.cts?.cancel()
        Manager.setContext(nil, for: target)
    }
    
    // Associated objects is a simplest way to bind Context and Target lifetimes
    // The implementation might change in the future.
    private static func getContext(for target: AnyObject) -> Context? {
        return objc_getAssociatedObject(target, &contextAK) as? Context
    }
    
    private static func setContext(_ context: Context?, for target: AnyObject) {
        objc_setAssociatedObject(target, &contextAK, context, .OBJC_ASSOCIATION_RETAIN)
    }
    
    private final class Context {
        var cts: CancellationTokenSource?
        
        init(_ cts: CancellationTokenSource) { self.cts = cts }
        
        // Automatically cancel the request when target deallocates.
        deinit { cts?.cancel() }
    }
}

private var contextAK = "Manager.Context.AssociatedKey"

public extension Manager {
    /// Loads an image into the given target. See the corresponding
    /// `loadImage(with:into)` method that takes `Request` for more info.
    public func loadImage(with url: URL, into target: Target) {
        loadImage(with: Request(url: url), into: target)
    }

    /// Loads an image and calls the given `handler`. The method itself
    /// **doesn't do** anything when the image is loaded - you have full
    /// control over how to display it, etc.
    ///
    /// The handler only gets called if the request is still associated with the
    /// `target` by the time it's completed. The handler gets called immediately
    /// if the image was stored in the memory cache.
    ///
    /// See `loadImage(with:into:)` method for more info.
    public func loadImage(with url: URL, into target: AnyObject, handler: @escaping Handler) {
        loadImage(with: Request(url: url), into: target, handler: handler)
    }
}

/// An enum representing either a success with a result value, or a failure.
public enum Result<T> {
    case success(T), failure(Error)
    
    /// Returns a `value` if the result is success.
    public var value: T? {
        if case let .success(val) = self { return val } else { return nil }
    }
    
    /// Returns an `error` if the result is failure.
    public var error: Error? {
        if case let .failure(err) = self { return err } else { return nil }
    }
}

/// Represents an arbitrary target for image loading.
public protocol Target: class {
    /// Callback that gets called when the request gets completed.
    func handle(response: Result<Image>, isFromMemoryCache: Bool)
}

#if os(macOS)
    import Cocoa
    /// Alias for `NSImageView`
    public typealias ImageView = NSImageView
#elseif os(iOS) || os(tvOS)
    import UIKit
    /// Alias for `UIImageView`
    public typealias ImageView = UIImageView
#endif


#if os(macOS) || os(iOS) || os(tvOS)
    
    /// Default implementation of `Target` protocol for `ImageView`.
    extension ImageView: Target {
        /// Displays an image on success. Runs `opacity` transition if
        /// the response was not from the memory cache.
        public func handle(response: Result<Image>, isFromMemoryCache: Bool) {
            guard let image = response.value else { return }
            self.image = image
            if !isFromMemoryCache {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.duration = 0.25
                animation.fromValue = 0
                animation.toValue = 1
                let layer: CALayer? = self.layer // Make compiler happy on macOS
                layer?.add(animation, forKey: "imageTransition")
            }
        }
    }
    
#endif
