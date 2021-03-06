%% Given a grid of voltages, applies a spatial filter
%
% Returns the spatially summed spectrum.
%
% ARGUMENTS:
%        obj -- nf object | a 3D matrix of values
%        p -- trace to use | sampling rate
%        kmax -- is the number of k-values to use. This should match with whatever kmax is set to in the analytic summation
%        n_windows -- s how many segments to average the time series over this gives extra spectral clarity at the expense of lower frequency resolution
%        spatial_filter -- set to 1 to enable the usual exponential k filter
%
% OUTPUT:
%        f -- vector of temporal frequencies in [Hz]
%        P -- power spectral density in [au / Hz ???]????
%        Kx -- vector with angular wavenumbers in [rad/m]
%        Ky -- vector with angular wavenumbers in [rad/m]
%        Pkf -- power spectral density? array in [units?????]
%        x -- array of spatial coordinates along x [m]
%        y -- array of spatial coordinates along y [m]
%        Prf --power spectral density ? in space frequency [units?????]
%
% REQUIRES:
%        nf.get_frequencies() 
%        nf.grid()  
%        nf.partition() 
%
% REFERENCES:
%
% AUTHOR:
%     Romesh Abeysuriya (2012-03-22).
%
% USAGE:
%{
    %
    [f, P, t, V] = nf.spatial_spectrum(nf, p, kmax, n_windows, spatial_filter)
%}
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [f, P, Kx, Ky, Pkf, x, y, Prf] = spatial_spectrum(obj, p, kmax, n_windows, spatial_filter)
    % First, work out the sampling rate in pixels per metre
    if isstruct(obj)
        if nargin < 2 || isempty(p)
            p = 'propagator.1.phi'; % Try the phi propagator first
        end
        data = nf.grid(obj, p);
        fs = 1.0 / obj.deltat;
    else
        data = obj;
        fs = p;
    end

    if any(isnan(data(:)))
        data = data(:, :, 1:(end - 1));
        if any(isnan(data(:)))
            error('NaNs are present in the data set')
        end
    end

    if mod(size(data, 1), 2) || mod(size(data, 2), 2)
        error('In order to have a zero frequency component, you need an even number of grid edge nodes');
    end

    if nargin < 5 || isempty(spatial_filter)
        spatial_filter = 1; % Spatially filter by default
    end

    if nargin < 4 || isempty(n_windows)
        n_windows = 8; % 8 windows by default
    end

    if nargin < 3 || isempty(kmax)
        kmax = []; % Use all k-values by default
    end

    % Calculate the temporal windows
    frac_overlap = 0.5;
    window_idx = nf.partition(size(data, 3), n_windows, [], frac_overlap, 1, 1);

    % Calculate the Fourier f and k values
    Lx = 0.5; % linear cortex dimension (m)
    Ly = 0.5;

    [f, Kx, Ky, x, y, ~, dk, ~] = nf.get_frequencies(data(:, :, window_idx(1, 1):window_idx(1, 2)), fs, Lx, Ly);

    k2 = Kx.^2 + Ky.^2; % Matrix of k-squared values
    if isempty(kmax)
        k_mask = ones(size(k2));
    else
        [center_x, center_y] = find(k2 == 0); % Get the centre entry
        [a, b] = meshgrid(1:size(k2, 1), 1:size(k2, 2));
        k_mask = abs(a - center_x) <= kmax & abs(b - center_y) <= kmax;
    end
    
    if spatial_filter
        % Calculate the value of k^2 at each grid node for spatial filtering
        k0 = 10; % spatial filter constant (m^-1)
        k_filter = exp(-k2 ./ k0^2);
    else
        k_filter = ones(size(k2));
    end

    Pkf = zeros(size(data, 1), size(data, 2), size(f, 1));
    Prf = zeros(size(data, 1), size(data, 2), size(f, 1));
    for j = 1:n_windows
        if nargout > 5
            [Pkf_new, Prf_new] = get_spectrum(data(:, :, window_idx(j, 1):window_idx(j, 2)), k_mask, k_filter, Lx, fs);
            Prf = Prf + Prf_new;
        else
            [Pkf_new] = get_spectrum(data(:, :, window_idx(j, 1):window_idx(j, 2)), k_mask, k_filter, Lx, fs);
        end
        Pkf = Pkf + Pkf_new;
    end

    Pkf = Pkf / n_windows;
    Prf = Prf / n_windows;

    P = squeeze(sum(sum(Pkf, 1), 2)) * dk * dk;
end %function spatial_spectrum()


function [Pkf, Prf] = get_spectrum(data, k_mask, k_filter, Lx, fs)
    df = fs / (size(data, 3)); % [Hz]
    dk = 2 * pi / Lx;          % spatial frequency resolution in [rad/m] -- smallest nonzero wavenumber
    dx = Lx / size(data, 1);   % [m]

    % First, get the 3D FFT and apply volume conduction
    P = fftshift(fftn(data));
    P = bsxfun(@times, P, k_mask);
    P = bsxfun(@times, P, sqrt(k_filter));

    % Next, perform the calculations for getting Pkf
    Pkf = abs(P).^2 / numel(data).^2;
    Pkf = Pkf / df / dk / dk; % Get the spectral density in all 3 dimensions
    Pkf = ifftshift(Pkf, 3); % Move the zero frequency from the middle back to the start of the grid
    Pkf = Pkf(:, :, 1:size(data, 3) / 2 + 1); % And truncate to only positive frequencies
    if rem(size(data, 3), 2) % Multiply by 2 to get correct energy, excluding zero and Nyquist frequencies
        Pkf(:, :, 2:end) = Pkf(:, :, 2:end) * 2;
    else
        Pkf(:, :, 2:(end - 1)) = Pkf(:, :, 2:(end - 1)) * 2;
    end

    if nargout > 1 % If the user requires Prf as well
        Prf = P; % Undo the forward FFT normalization
        Prf = ifft(ifftshift(Prf, 1), [], 1); % Take the inverse transform in the spatial dimensions
        Prf = ifft(ifftshift(Prf, 2), [], 2);
        Prf = ifftshift(Prf, 3); % Move the zero frequency from the middle back to the start of the grid

        Prf = abs(Prf).^2 / size(Prf, 3).^2;
        Prf = Prf / df;

        Prf = Prf(:, :, 1:size(data, 3) / 2 + 1);
        if rem(size(data, 3), 2) % Multiply by 2 to get correct energy, excluding zero and Nyquist frequencies
            Prf(:, :, 2:end) = Prf(: ,:, 2:end) * 2;
        else
            Prf(:, :, 2:(end - 1)) = Prf(:, :, 2:(end - 1)) * 2;
        end
        
        % Divide by N, dx and dx so that integration gives the correct power or PSD?????
        % Division by N on the grounds that energy in real space is given by summing abs(x)^2/N
        % So we could call the power P=abs(x)^2/N so that sum(P) gives the correct power
        % And then division by dx*dx means that integral(P) over position gives the right answer
        Prf = Prf / size(data, 1) / size(data, 2) / dx / dx;
    end
end %function get_spectrum()
