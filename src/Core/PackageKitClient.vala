/*-
 * Copyright (c) 2019 elementary LLC. (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: David Hewitt <davidmhewitt@gmail.com>
 */

public class AppCenterCore.PackageKitClient : Object {
    private static Task client;
    private AsyncQueue<PackageKitJob> jobs = new AsyncQueue<PackageKitJob> ();
    private Thread<bool> worker_thread;

    private bool worker_func () {
		while (true) {
            var job = jobs.pop ();
            switch (job.operation) {
                case PackageKitJob.Type.STOP_THREAD:
                    return true;
                case PackageKitJob.Type.GET_INSTALLED_PACKAGES:
                    get_installed_packages_internal (job);
                    break;
                case PackageKitJob.Type.GET_NOT_INSTALLED_DEPS_FOR_PACKAGE:
                    get_not_installed_deps_for_package_internal (job);
                    break;
                case PackageKitJob.Type.INSTALL_PACKAGES:
                    install_packages_internal (job);
                    break;
			    default:
				    assert_not_reached ();
		    }
        }
	}

    static construct {
        client = new Task ();
    }

    private PackageKitClient () {
        worker_thread = new Thread<bool> ("packagekit-worker", worker_func);
    }

    ~PackageKitClient () {
        warning ("stopping packagekit thread");
        jobs.push (new PackageKitJob (PackageKitJob.Type.STOP_THREAD));
        worker_thread.join ();
    }

    private void get_installed_packages_internal (PackageKitJob job) {
        Pk.Bitfield filter = Pk.Bitfield.from_enums (Pk.Filter.INSTALLED, Pk.Filter.NEWEST);
        var installed = new Gee.TreeSet<Pk.Package> ();

        try {
            Pk.Results results = client.get_packages (filter, null, (prog, type) => {});
            results.get_package_array ().foreach ((pk_package) => {
                installed.add (pk_package);
            });

        } catch (Error e) {
            critical (e.message);
        }

        job.result = Value (typeof (Object));
        job.result.take_object (installed);
        job.results_ready ();
    }

    public async Gee.TreeSet<Pk.Package> get_installed_packages () {
        var job = new PackageKitJob (PackageKitJob.Type.GET_INSTALLED_PACKAGES);
        SourceFunc callback = get_installed_packages.callback;
        job.results_ready.connect (() => {
            Idle.add ((owned) callback);
        });

        jobs.push (job);
        yield;
        return (Gee.TreeSet<Pk.Package>)job.result.get_object ();
    }

    private void get_not_installed_deps_for_package_internal (PackageKitJob job) {
        var pk_package = (Pk.Package)job.args[0].get_object ();
        var cancellable = (Cancellable)job.args[1].get_object ();

        var deps = new Gee.ArrayList<Pk.Package> ();

        if (pk_package == null) {
            job.result = Value (typeof (Object));
            job.result.take_object (deps);
            job.results_ready ();
            return;
        }

        string[] package_array = { pk_package.package_id, null };
        var filters = Pk.Bitfield.from_enums (Pk.Filter.NOT_INSTALLED);
        try {
            var deps_result = client.depends_on (filters, package_array, false, cancellable, (p, t) => {});
            deps_result.get_package_array ().foreach ((dep_package) => {
                deps.add (dep_package);
            });

            package_array = {};
            foreach (var dep_package in deps) {
                package_array += dep_package.package_id;
            }

            package_array += null;
            if (package_array.length > 1) {
                deps_result = client.depends_on (filters, package_array, true, cancellable, (p, t) => {});
                deps_result.get_package_array ().foreach ((dep_package) => {
                    deps.add (dep_package);
                });
            }
        } catch (Error e) {
            warning ("Error fetching dependencies for %s: %s", pk_package.package_id, e.message);
        }

        job.result = Value (typeof (Object));
        job.result.take_object (deps);
        job.results_ready ();
    }

    public async Gee.ArrayList<Pk.Package> get_not_installed_deps_for_package (Pk.Package? package, Cancellable? cancellable) {
        if (package == null) {
            return new Gee.ArrayList<Pk.Package> ();
        }

        var job = new PackageKitJob (PackageKitJob.Type.GET_NOT_INSTALLED_DEPS_FOR_PACKAGE);
        job.args = new Value[2];

        job.args[0] = Value (typeof (Object));
        job.args[0].take_object (package);

        job.args[1] = Value (typeof (Object));
        job.args[1].take_object (cancellable);

        SourceFunc callback = get_not_installed_deps_for_package.callback;
        job.results_ready.connect (() => {
            Idle.add ((owned) callback);
        });

        jobs.push (job);
        yield;
        return (Gee.ArrayList<Pk.Package>)job.result.get_object ();
    }

    private void install_packages_internal (PackageKitJob job) {
        var args = (InstallPackagesJob)job.args[0].get_object ();
        var package_ids = args.package_ids;
        unowned Pk.ProgressCallback cb = args.cb;
        var cancellable = args.cancellable;

        Pk.Exit exit_status = Pk.Exit.UNKNOWN;
        string[] packages_ids = {};
        foreach (var pkg_name in package_ids) {
            packages_ids += pkg_name;
        }

        packages_ids += null;

        try {
            var results = client.resolve (Pk.Bitfield.from_enums (Pk.Filter.NEWEST, Pk.Filter.ARCH), packages_ids, cancellable, () => {});

            /*
             * If there were no packages found for the requested architecture,
             * try to resolve IDs by not searching for this architecture
             * e.g: filtering 32 bit only package on a 64 bit system
             */
            GenericArray<weak Pk.Package> package_array = results.get_package_array ();
            if (package_array.length == 0) {
                results = client.resolve (Pk.Bitfield.from_enums (Pk.Filter.NEWEST, Pk.Filter.NOT_ARCH), packages_ids, cancellable, () => {});
                package_array = results.get_package_array ();
            }

            packages_ids = {};
            package_array.foreach ((package) => {
                packages_ids += package.package_id;
            });

            packages_ids += null;

            results = client.install_packages_sync (packages_ids, cancellable, cb);
            exit_status = results.get_exit_code ();
        } catch (Error e) {
            job.error = e;
            job.results_ready ();
            return;
        }

        job.result = Value (typeof(Pk.Exit));
        job.result.set_enum (exit_status);
        job.results_ready ();
    }

    public async Pk.Exit install_packages (Gee.ArrayList<string> package_ids, owned Pk.ProgressCallback cb, Cancellable cancellable) throws GLib.Error {
        var job = new PackageKitJob (PackageKitJob.Type.INSTALL_PACKAGES);
        job.args = new Value[1];

        var job_args = new InstallPackagesJob ();
        job_args.package_ids = package_ids;
        job_args.cb = (owned)cb;
        job_args.cancellable = cancellable;

        job.args[0] = Value (typeof (Object));
        job.args[0].take_object (job_args);

        SourceFunc callback = install_packages.callback;
        job.results_ready.connect (() => {
            Idle.add ((owned) callback);
        });

        jobs.push (job);
        yield;

        if (job.error != null) {
            throw job.error;
        }

        return (Pk.Exit)job.result.get_enum ();
    }

    private static GLib.Once<PackageKitClient> instance;
    public static unowned PackageKitClient get_default () {
        return instance.once (() => { return new PackageKitClient (); });
    }
}
